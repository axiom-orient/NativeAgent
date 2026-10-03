#!/bin/zsh
set -euo pipefail

project=""; scheme=""; udid=""; coredevice=""; bundle=""; team="${HARNESS_DEVELOPMENT_TEAM:-}"; extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --scheme) scheme="$2"; shift 2 ;;
    --udid) udid="$2"; shift 2 ;;
    --coredevice) coredevice="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --team) team="$2"; shift 2 ;;
    --) shift; extra_args=("$@"); break ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done
[[ -n "$project" && -n "$scheme" && -n "$udid" && -n "$coredevice" && -n "$bundle" ]] || { echo "--project/--scheme/--udid/--coredevice/--bundle required"; exit 2; }
[[ -n "$team" ]] || { echo "set HARNESS_DEVELOPMENT_TEAM or pass --team"; exit 2; }

derived="/tmp/harness-kit-dd-${scheme}"
xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
  -destination "platform=iOS,id=$udid" -derivedDataPath "$derived" \
  -skipPackagePluginValidation CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" build

app=$(find "$derived/Build/Products" -name "*.app" -path "*iphoneos*" | head -1)
xcrun devicectl device install app --device "$coredevice" "$app"
xcrun devicectl device process launch --device "$coredevice" "$bundle" "${extra_args[@]}"
print -- "launched $bundle; pull report with device-pull-report.sh"
