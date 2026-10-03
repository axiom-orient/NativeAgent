#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/ask-consumer-verify.XXXXXX")"
fixture_path="$scratch_root/probe.hwpx"
trap 'rm -rf "$scratch_root"' EXIT

print -- "==> facade consumer"
swift run \
    --package-path "$repo_root/Verification/FacadeConsumer" \
    --scratch-path "$scratch_root/facade" \
    -Xswiftc -warnings-as-errors

base64 -D \
    -i "$repo_root/Verification/DeepConsumer/Fixtures/probe.hwpx.base64" \
    -o "$fixture_path"

print -- "==> deep consumer"
ASK_HWPX_FIXTURE="$fixture_path" swift run \
    --package-path "$repo_root/Verification/DeepConsumer" \
    --scratch-path "$scratch_root/deep" \
    -Xswiftc -warnings-as-errors
