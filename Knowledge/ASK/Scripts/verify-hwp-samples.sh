#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
sample_root="${RHWP_SAMPLES_ROOT:-/tmp/ask-rhwp-upstream/samples}"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/ask-hwp-sample-verification.XXXXXX")"
trap 'rm -rf "$scratch_root"' EXIT
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"

sample_paths=(
    "hwp3-sample-hwpx.hwpx"
    "issue1510_coanchored_float_tables.hwpx"
    "task1716/table_scattered_header_rowbreak.hwpx"
    "hwp_table_test.hwp"
    "hwp3-sample16-hwp5-2024.hwp"
    "test-image.hwp"
    "atop-equation-01.hwp"
    "footnote-01.hwp"
)

for relative_path in "${sample_paths[@]}"; do
    sample_path="$sample_root/$relative_path"
    if [[ ! -f "$sample_path" ]]; then
        print -u2 -- "Missing rHWP sample: $sample_path"
        print -u2 -- "Set RHWP_SAMPLES_ROOT to the directory containing the upstream samples/ tree."
        exit 66
    fi
done

absolute_paths=()
for relative_path in "${sample_paths[@]}"; do
    absolute_paths+=("$sample_root/$relative_path")
done

print -- "==> HWP/HWPX sample consumer"
DEVELOPER_DIR="$developer_dir" \
swift run \
    --package-path "$repo_root/Verification/HWPSampleConsumer" \
    --scratch-path "$scratch_root" \
    -Xswiftc -warnings-as-errors \
    HWPSampleConsumer -- \
    "${absolute_paths[@]}"
