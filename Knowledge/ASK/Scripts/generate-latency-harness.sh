#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

xcodegen generate \
    --spec "$repo_root/Verification/ASKLatencyHarness/project.yml" \
    --project "$repo_root/Verification/ASKLatencyHarness"
