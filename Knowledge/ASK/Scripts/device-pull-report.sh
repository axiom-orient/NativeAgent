#!/bin/zsh
set -euo pipefail

coredevice=""; bundle=""; source_path="Documents/harness-report.json"; destination="./harness-report.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --coredevice) coredevice="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --source) source_path="$2"; shift 2 ;;
    --destination) destination="$2"; shift 2 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done
[[ -n "$coredevice" && -n "$bundle" ]] || { echo "--coredevice/--bundle required"; exit 2; }

xcrun devicectl device copy from --device "$coredevice" \
  --domain-type appDataContainer --domain-identifier "$bundle" \
  --source "$source_path" --destination "$destination"
print -- "pulled to $destination"
