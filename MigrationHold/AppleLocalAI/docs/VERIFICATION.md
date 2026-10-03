# AppleLocalAI — Verification

## Required gates

### Portable rules

Workspace root에서 `python3 tools/verify-portable.py`를 실행하면 AppleLocalAICore, operation controller, 선택형 adapter의 FoundationModels 비의존 부분을 검증한다. 이것은 Apple SDK compile/link 증거가 아니다.

### Apple SDK

지원 macOS/Xcode 환경에서 실행한다.

```sh
swift test --package-path AppleLocalAI -Xswiftc -warnings-as-errors
swift test --package-path AppleLocalAI/Packages/AppleLocalAILocalModels -Xswiftc -warnings-as-errors
swift test --package-path AppleLocalAI/Packages/AppleLocalAILEAP -Xswiftc -warnings-as-errors
swift test --package-path AppleLocalAI/Packages/NativeAgentProviderAppleLocalAI -Xswiftc -warnings-as-errors
```

### Device/native

실제 모델별로 load → generate/stream → cancel → drain → unload를 검증한다. LEAP iOS binary는 actual app signing/dyld까지 확인한다.

## Reporting

각 gate는 `PASS`, `FAIL`, `SKIPPED_ENV`, `NOT_RUN` 중 하나로 기록한다. source parse나 fixture test를 native inference PASS로 승격하지 않는다.
