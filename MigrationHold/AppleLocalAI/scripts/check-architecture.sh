#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$ROOT/Sources/AppleLocalAICore" ] || fail "missing core target"
[ -d "$ROOT/Sources/AppleLocalAI" ] || fail "missing Foundation Models runtime target"
[ -d "$ROOT/Packages/AppleLocalAILocalModels/Sources/AppleLocalAILocalModels" ] || fail "missing local-model target"
[ -d "$ROOT/Packages/AppleLocalAILEAP/Sources/AppleLocalAILEAP" ] || fail "missing LEAP adapter target"

for forbidden in \
  AppleLocalAIProvider \
  AppleLocalAIWire \
  AppleLocalAIConsole \
  AppleLocalAIModelAsset \
  AppleLocalAIFileFormat \
  AppleLocalAIAssetError \
  AppleLocalAICoreLanguageModel \
  AppleLocalAIMLXLanguageModel \
  AppleLocalAILiteRTLanguageModel \
  AppleLocalAILiteRTModelCapabilities \
  AppleLocalAILiteRTModelInspector \
  AppleLocalAILiteRTConfiguration \
  AppleLocalAILiteRTBackendChoice \
  AppleLocalAILiteRTVisionBackendChoice \
  NIOCore \
  NIOHTTP1 \
  ChatCompletionsLanguageModel \
  RemoteLanguageModelConfiguration; do
  if grep -R -n --exclude='check-architecture.sh' "$forbidden" \
    "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Packages" "$ROOT/Package.swift" \
    "$ROOT/README.md" "$ROOT/docs" >/dev/null 2>&1; then
    fail "legacy/remote symbol remains: $forbidden"
  fi
done

if grep -R -n '#if os(macOS)' "$ROOT/Sources" >/dev/null 2>&1; then
  fail "unexpected macOS-only source gate"
fi

if grep -R -n --exclude='check-architecture.sh' --exclude-dir=.build 'FoundationModelsUtilities' "$ROOT" >/dev/null 2>&1; then
  fail "unused FoundationModelsUtilities dependency remains"
fi

if grep -R -n 'import FoundationModels\|import Vision\|CoreAILanguageModels\|MLXFoundationModels\|LiteRTLM' "$ROOT/Sources/AppleLocalAICore" >/dev/null 2>&1; then
  fail "pure core imports runtime frameworks"
fi

for boundary in AppleLocalAICore AppleLocalAI; do
  if grep -R -n 'LEAPProvider\|LanguageModelCore\|LanguageModelRuntime\|ModelArtifactStore' "$ROOT/Sources/$boundary" >/dev/null 2>&1; then
    fail "LEAP/NativeAgent dependency crossed into $boundary"
  fi
done

# Only this optional package translates NativeAgent contracts. The SDK root and
# every other package keep their original independent boundary.
for scope in "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Package.swift" "$ROOT"/Packages/*; do
  [ "$scope" = "$ROOT/Packages/NativeAgentProviderAppleLocalAI" ] && continue
  if grep -R -n --exclude='check-architecture.sh' --exclude-dir=.build --exclude-dir=.runtime \
    'LEAPProvider\|LanguageModelCore\|LanguageModelRuntime\|ModelArtifactStore' \
    "$scope" >/dev/null 2>&1; then
    fail "NativeAgent contract dependency is allowed only in the explicit optional adapter"
  fi
done

if grep -n 'NativeAgentProviderAppleLocalAI' "$ROOT/Package.swift" >/dev/null 2>&1; then
  fail "optional adapter must not enter the root dependency graph"
fi

ADAPTER="$ROOT/Packages/NativeAgentProviderAppleLocalAI"
if [ -d "$ADAPTER" ] && grep -R -n --exclude-dir=.build \
  'import MLXProvider\|import LEAPProvider\|import LiteRTProvider\|import LeapSDK\|import MLX\|import LiteRTLM\|import ModelArtifactStore' \
  "$ADAPTER/Sources" "$ADAPTER/Package.swift" >/dev/null 2>&1; then
  fail "optional adapter must not own a vendor loader or artifact store"
fi

echo "architecture-check: OK"
