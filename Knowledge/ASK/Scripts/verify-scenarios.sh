#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/ask-scenario-verify.XXXXXX")"
trap 'rm -rf "$scratch_root"' EXIT

package_path="$repo_root/Verification/ScenarioConsumer"
swift build \
    --package-path "$package_path" \
    --scratch-path "$scratch_root/package" \
    -Xswiftc -warnings-as-errors

scenario_binary="$(swift build --package-path "$package_path" --scratch-path "$scratch_root/package" --show-bin-path)/ScenarioConsumer"
verification_status=0

"$scenario_binary" --core || verification_status=1
for case_index in {0..9}; do
    "$scenario_binary" --markdown-case "$case_index" || verification_status=1
done
for generated_index in {0..119}; do
    "$scenario_binary" --markdown-generated-case "$generated_index" || verification_status=1
done

if (( verification_status != 0 )); then
    exit "$verification_status"
fi

print -- "SCENARIO VERIFICATION PASS"
