# AppleLocalAI

> 이 문서의 기존 상세 기록은 해당 subsystem 기준이다. 이번 리뉴얼의 최신 상태와 미검증 범위는 [workspace 검증](../../docs/verification/README.md)이 소유한다. MigrationHold를 활성 완료 기능으로 해석하지 않는다.


AppleLocalAI는 **Apple Foundation Models API를 중심으로 native language-model session을 제공하는 독립 Swift package**다. Root package는 session/core만 소유하고, MLX/CoreAI/LiteRT/LEAP 같은 vendor backend는 필요할 때 별도 package로 선택한다.

- Swift tools: **6.4**
- Platforms: **iOS 27+, macOS 27+**
- Root products: `AppleLocalAICore`, `AppleLocalAI`

## 사용

이 폴더의 `Package.swift`를 직접 추가한다. NativeAgent는 root dependency가 아니다.

```swift
import AppleLocalAI
import FoundationModels

let profile = try AppleLocalAIProfile(
  model: SystemLanguageModel.default,
  instructions: "Answer concisely."
)
let session = try AppleLocalAISession(profile: profile)
let response = try await session.respond(to: AppleLocalAIRequest(text: "Hello"))
print(response.text)
```

정확한 initializer와 model availability는 실제 source/API를 기준으로 한다. Root package는 local vendor model을 자동 다운로드하거나 자동 fallback하지 않는다.

## Optional packages

| Package | 역할 |
|---|---|
| [`Packages/AppleLocalAILocalModels`](Packages/AppleLocalAILocalModels/README.md) | CoreAI / MLX / LiteRT 기반 local `LanguageModel` 선택 |
| [`Packages/NativeAgentProviderAppleLocalAI`](Packages/NativeAgentProviderAppleLocalAI/README.md) | NativeAgent runtime 공유용 선택 adapter; 별도 실행 시스템 아님 |
| [`Packages/AppleLocalAILEAP`](Packages/AppleLocalAILEAP/README.md) | LEAP text/audio runtime 및 `LanguageModel` adapter |

NativeAgent와 같은 local resident를 공유하려면 standalone loader를 별도로 만들지 말고 [`NativeAgentProviderAppleLocalAI`](Packages/NativeAgentProviderAppleLocalAI/README.md)의 borrowed runtime composition을 사용한다.

## 핵심 규칙

- `AppleLocalAISession`은 transcript와 operation lifecycle을 소유한다.
- 선택 `LanguageModel`의 resident lifetime은 그 model/provider owner가 소유한다.
- shared NativeAgent composition에서는 host `LocalBackend`가 resident owner다.
- cancel은 native cleanup 완료와 동일하지 않다.
- unsupported capability를 조용히 제거하거나 다른 모델로 fallback하지 않는다.

## 문서

- [`AGENTS.md`](AGENTS.md) — 이 package를 수정하는 에이전트 규칙.
- [`IDENTITY_AND_EVOLUTION`](docs/IDENTITY_AND_EVOLUTION.md) — 제품 정체성/발전 방향.
- [`ARCHITECTURE`](docs/ARCHITECTURE.md) — session/core/vendor 경계.
- [`SPEC`](docs/SPEC.md) — public behavior contract.
- [`IMPLEMENTATION_STATUS`](docs/IMPLEMENTATION_STATUS.md) — 현재 구현/검증 상태.
- [`VERIFICATION`](docs/VERIFICATION.md) — 재현 가능한 gate.
- [`PLAN`](docs/PLAN.md) — 남은 작업.
