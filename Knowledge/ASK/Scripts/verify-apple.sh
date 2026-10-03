#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
ios_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/ask-apple-verify.XXXXXX")"
trap 'rm -rf "$scratch_root"' EXIT

for manifest in "$repo_root"/Packages/*/Package.swift; do
    package_dir="${manifest:h}"
    package_name="${package_dir:t}"
    print -- "==> macOS tests: $package_name"
    swift test \
        --package-path "$package_dir" \
        --scratch-path "$scratch_root/${package_name}-macos" \
        -Xswiftc -warnings-as-errors
    if [[ "$package_name" == "ASKMCP" ]]; then
        # The package's executable products are host CLI servers, not iOS apps.
        # Build the library target that owns the iOS-compatible API surface.
        print -- "==> iOS simulator library build: $package_name (ASKMCPHTTP)"
        swift build \
            --package-path "$package_dir" \
            --scratch-path "$scratch_root/${package_name}-ios" \
            --target ASKMCPHTTP \
            --triple arm64-apple-ios17.0-simulator \
            --sdk "$ios_sdk" \
            -Xswiftc -warnings-as-errors
    else
        print -- "==> iOS simulator build: $package_name"
        swift build \
            --package-path "$package_dir" \
            --scratch-path "$scratch_root/${package_name}-ios" \
            --triple arm64-apple-ios17.0-simulator \
            --sdk "$ios_sdk" \
            -Xswiftc -warnings-as-errors
    fi
done

print -- "==> macOS facade tests"
swift test \
    --package-path "$repo_root" \
    --scratch-path "$scratch_root/root-macos" \
    -Xswiftc -warnings-as-errors
print -- "==> iOS simulator facade build"
swift build \
    --package-path "$repo_root" \
    --scratch-path "$scratch_root/root-ios" \
    --triple arm64-apple-ios17.0-simulator \
    --sdk "$ios_sdk" \
    -Xswiftc -warnings-as-errors
