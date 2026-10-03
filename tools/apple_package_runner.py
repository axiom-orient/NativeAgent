"""Run SwiftPM package schemes against an iOS Simulator on macOS."""

from functools import lru_cache
import json
import os
from pathlib import Path
import platform
import subprocess


def uses_xcode_ios_runner() -> bool:
    return platform.system() == "Darwin"


@lru_cache(maxsize=1)
def ios_destination() -> str:
    explicit = os.environ.get("NATIVEAI_IOS_DESTINATION")
    if explicit:
        return explicit

    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
    )
    devices = json.loads(result.stdout).get("devices", {})
    candidates = []
    for runtime, runtime_devices in devices.items():
        if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        for device in runtime_devices:
            if not device.get("isAvailable", True):
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
        raise RuntimeError("No available iOS Simulator destination was found.")

    candidates.sort()
    return f"platform=iOS Simulator,id={candidates[0][3]}"


@lru_cache(maxsize=None)
def package_name(package: Path) -> str:
    result = subprocess.run(
        ["swift", "package", "--package-path", str(package), "dump-package"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)["name"]


def xcodebuild_command(package: Path, action: str, derived_data: Path) -> list[str]:
    if action not in {"build", "test"}:
        raise ValueError(f"Unsupported Xcode package action: {action}")
    return [
        "xcodebuild",
        "-scheme",
        package_name(package),
        "-destination",
        ios_destination(),
        "-derivedDataPath",
        str(derived_data),
        "-parallelizeTargets",
        "-jobs",
        "4",
        action,
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
    ]
