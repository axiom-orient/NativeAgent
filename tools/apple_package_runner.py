"""Run SwiftPM package schemes against an iOS Simulator on macOS."""

from functools import lru_cache
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile


def uses_xcode_ios_runner() -> bool:
    return platform.system() == "Darwin"


@lru_cache(maxsize=1)
def ios_destination() -> str:
    permitted = {
        "B462783D-86CD-46ED-8C12-E147F20A65C1": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "6F7E3B30-7343-4290-8F67-399ED0A20EBC": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    }
    explicit = os.environ.get("NATIVEAI_IOS_DESTINATION")
    if explicit:
        parts = dict(part.split("=", 1) for part in explicit.split(",") if "=" in part)
        if parts.get("platform") != "iOS Simulator" or parts.get("id") not in permitted:
            raise ValueError("The iOS destination must identify one of the two approved existing simulators.")
        return explicit

    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    devices = json.loads(result.stdout).get("devices", {})
    candidates = []
    for runtime, runtime_devices in devices.items():
        if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        for device in runtime_devices:
            if not device.get("isAvailable", True):
                continue
            if permitted.get(device["udid"]) != runtime:
                continue
            candidates.append(
                (
                    0 if device.get("state") == "Booted" else 1,
                    runtime,
                    device.get("name", ""),
                    device["udid"],
                )
            )
    if not candidates:
        raise RuntimeError("Neither approved existing iOS Simulator is available; no device was created.")

    candidates.sort()
    return f"platform=iOS Simulator,id={candidates[0][3]}"


@lru_cache(maxsize=None)
def package_scheme(package: Path, target: str | None = None) -> str:
    command = ["xcodebuild", "-list", "-json"]
    with tempfile.TemporaryFile(mode="w+") as output, tempfile.TemporaryFile(mode="w+") as errors:
        code = run_package_command(command, package, output, timeout=60, stderr=errors)
        output.seek(0)
        errors.seek(0)
        stdout, stderr = output.read(), errors.read()
    if code:
        raise subprocess.CalledProcessError(code, command, output=stdout, stderr=stderr)
    workspace = json.loads(stdout)["workspace"]
    schemes = workspace["schemes"]
    if target is not None:
        if target not in schemes:
            raise ValueError(f"Package {package} has no scheme for target {target}.")
        return target
    name = workspace["name"]
    # A product scheme can omit sibling test targets. Prefer the complete package.
    for candidate in (f"{name}-Package", name):
        if candidate in schemes:
            return candidate
    raise ValueError(f"No package test scheme found for {package}: {schemes}")


def xcodebuild_command(
    package: Path, action: str, derived_data: Path, target: str | None = None
) -> list[str]:
    if action not in {"build", "test"}:
        raise ValueError(f"Unsupported Xcode package action: {action}")
    return [
        "xcodebuild",
        "-scheme",
        package_scheme(package, target),
        "-destination",
        ios_destination(),
        "-derivedDataPath",
        str(derived_data),
        "-parallelizeTargets",
        "-jobs",
        "4",
        "-parallel-testing-enabled",
        "NO",
        action,
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "SWIFT_SUPPRESS_WARNINGS=NO",
    ]


def run_package_command(
    command, package, log, *, timeout, environment=None, stderr=subprocess.STDOUT
) -> int:
    """Run in the owning package and join the compiler group on interruption."""
    with subprocess.Popen(
        command, cwd=package, env=environment, stdout=log,
        stderr=stderr, start_new_session=True,
    ) as process:
        try:
            return process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            try:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass
            finally:
                # The parent can exit while a compiler child ignores SIGTERM.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=10)
            log.write("\nInterrupted/timed out: owned compiler group was terminated.\n")
            return 124
