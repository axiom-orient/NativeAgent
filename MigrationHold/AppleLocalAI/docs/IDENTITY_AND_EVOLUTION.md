# AppleLocalAI — Identity and Evolution

## 정체성

AppleLocalAI는 Apple의 `FoundationModels` API를 **앱 내부의 명시적 native AI session 경계**로 사용하는 Swift SDK다. 목표는 provider를 하나로 숨기는 것이 아니라, Apple session semantics를 유지하면서 local model 선택을 교체 가능하게 하는 것이다.

## 불변조건

- `AppleLocalAISession`이 transcript/session operation의 owner다.
- model provider의 resident/download/cache owner를 session이 암묵적으로 복제하지 않는다.
- root package는 vendor dependency를 강제하지 않는다.
- unsupported feature는 명시 오류로 처리한다.
- cancellation, response stream 종료, native cleanup을 같은 사건으로 취급하지 않는다.
- actual Apple SDK/device evidence 없이 production success를 주장하지 않는다.

## 변경 가능한 것

model provider, history policy, response projection, optional package 내부 구현과 performance tuning은 위 불변조건을 지키면 교체 가능하다.

## 발전 방향

1. Foundation Models native API와 custom `LanguageModel` adapters를 지원 SDK에서 검증한다.
2. local vendor package는 필요 capability만 선택적으로 제공한다.
3. NativeAgent와의 shared backend는 외부 integration을 통해 borrowed runtime으로 연결한다.
4. capability 광고는 실제 구현·검증 수준과 일치시킨다.
