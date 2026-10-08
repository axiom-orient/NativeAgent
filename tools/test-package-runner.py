#!/usr/bin/env python3
"""Runner regressions. Native compilation is verified by the package scripts."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from apple_package_runner import ios_destination, package_scheme, run_package_command, xcodebuild_command


class PackageSchemeTests(unittest.TestCase):
    def tearDown(self):
        package_scheme.cache_clear()

    def discovery(self, schemes):
        def run(command, package, log, **kwargs):
            log.write(json.dumps({"workspace": {"name": "Example", "schemes": schemes}}))
            return 0
        return run

    def test_complete_package_includes_sibling_products(self):
        with patch("apple_package_runner.run_package_command", side_effect=self.discovery([
            "Example", "Example-Package", "Sibling"
        ])) as discover:
            self.assertEqual(package_scheme(Path("/source/Example")), "Example-Package")
            self.assertEqual(discover.call_args.args[1], Path("/source/Example"))

    def test_single_product_and_explicit_build_target(self):
        with patch("apple_package_runner.run_package_command", side_effect=self.discovery([
            "Example", "Sibling"
        ])):
            self.assertEqual(package_scheme(Path("/source/Example")), "Example")
            with patch("apple_package_runner.ios_destination", return_value="platform=iOS Simulator,id=test"):
                command = xcodebuild_command(Path("/source/Example"), "build", Path("/scratch"), "Sibling")
            self.assertEqual(command[command.index("-scheme") + 1], "Sibling")

    def test_missing_target_never_falls_back_to_other_product(self):
        with patch("apple_package_runner.run_package_command", side_effect=self.discovery(["Example"])):
            with self.assertRaises(ValueError):
                package_scheme(Path("/source/Example"), "Missing")

    def test_unknown_package_scheme_is_not_guessed(self):
        with patch("apple_package_runner.run_package_command", side_effect=self.discovery(["Dependency"])):
            with self.assertRaises(ValueError):
                package_scheme(Path("/source/Example"))

    def test_failed_discovery_preserves_exit_and_cannot_select_a_scheme(self):
        with patch("apple_package_runner.run_package_command", return_value=124) as discover:
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                package_scheme(Path("/source/Example"))
            self.assertEqual(failure.exception.returncode, 124)
            self.assertEqual(discover.call_args.kwargs["timeout"], 60)


class SimulatorSelectionTests(unittest.TestCase):
    def tearDown(self):
        ios_destination.cache_clear()

    def test_only_existing_approved_devices_can_be_selected(self):
        payload = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "unapproved", "name": "iPhone 15", "state": "Booted", "isAvailable": True},
            {"udid": "B462783D-86CD-46ED-8C12-E147F20A65C1", "name": "iPhone 17 Pro Max", "state": "Shutdown", "isAvailable": True},
        ]}}
        with patch.dict(os.environ, {}, clear=True), patch("apple_package_runner.subprocess.run") as run:
            run.return_value.stdout = json.dumps(payload)
            self.assertEqual(ios_destination(), "platform=iOS Simulator,id=B462783D-86CD-46ED-8C12-E147F20A65C1")
            self.assertEqual(run.call_args.args[0], ["xcrun", "simctl", "list", "devices", "available", "-j"])

    def test_unapproved_override_is_rejected_without_dispatch(self):
        with patch.dict(os.environ, {"NATIVEAI_IOS_DESTINATION": "platform=iOS Simulator,id=unapproved"}, clear=True), patch("apple_package_runner.subprocess.run") as run:
            with self.assertRaises(ValueError):
                ios_destination()
            run.assert_not_called()

    def test_missing_approved_devices_never_creates_a_device(self):
        with patch.dict(os.environ, {}, clear=True), patch("apple_package_runner.subprocess.run") as run:
            run.return_value.stdout = json.dumps({"devices": {}})
            with self.assertRaises(RuntimeError):
                ios_destination()
            self.assertEqual(run.call_count, 1)


class PackageExecutionTests(unittest.TestCase):
    def test_package_directory_environment_and_nonzero_exit_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with (root / "run.log").open("w") as log:
                code = run_package_command([
                    sys.executable, "-c",
                    "import os; print(os.getcwd()); print(os.environ['RUNNER_TEST_VALUE']); raise SystemExit(7)",
                ], root, log, timeout=10, environment={**os.environ, "RUNNER_TEST_VALUE": "fixture"})
            self.assertEqual(code, 7)
            self.assertEqual((root / "run.log").read_text().splitlines(), [str(root), "fixture"])

    @unittest.skipUnless(hasattr(os, "killpg"), "POSIX process groups required")
    def test_timeout_terminates_child_even_when_parent_exits_first(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            child = ("import os,signal,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                     "Path('child.pid').write_text(str(os.getpid())); time.sleep(60)")
            parent = ("import subprocess,sys,time; "
                      f"subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(60)")
            pid = None
            try:
                with (root / "run.log").open("w") as log:
                    code = run_package_command([sys.executable, "-c", parent], root, log, timeout=1)
                self.assertEqual(code, 124)
                pid = int((root / "child.pid").read_text())
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
                    if result.returncode != 0 or result.stdout.strip().startswith("Z"):
                        break
                    time.sleep(0.01)
                else:
                    self.fail("Compiler child survived timeout supervision")
            finally:
                if pid is not None:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
