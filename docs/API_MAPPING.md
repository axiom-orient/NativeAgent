# API / Package Migration Map

아래 rename은 입력 기준선에 이미 반영된 설계 P2의 module/product clean break다. 이번 비판적 검토에서는 추가 public rename·wrapper·schema 변경을 하지 않았다.
기존 import의 자동 호환을 약속하는 deprecated module wrapper는 만들지 않았다.
request/event/turn와 Agent public 동작은 유지하고, native 소비자가 확인되기 전 기존 AppleLocalAI는 보존했다.

| 이전 | 현재 module/product | 위치 / 판단 |
|---|---|---|
| NativeAgentModelCore | LanguageModelCore | `Model/LanguageModelCore` |
| NativeAgentModelRuntime | LanguageModelRuntime | `Model/LanguageModelRuntime` |
| NativeAgentArtifactStore | ModelArtifactStore | module 및 공개 store type 이름도 변경 |
| NativeAgentModelHub | ModelHub | `Model/ModelHub` |
| NativeAgentProviderMLX / NativeAgentMLXRegistry | MLXProvider / MLXModelRegistry | `Providers/MLX` |
| NativeAgentProviderLiteRT | LiteRTProvider | `Providers/LiteRT` |
| NativeAgentProviderLEAP | LEAPProvider | `Providers/LEAP` |
| NativeAgentProviderFoundationModels | AppleSystemModelProvider | `Providers/AppleSystemModel`, 기존 26 경로 |
| NativeAgentChatGPTAccount | ChatGPTAccount | `Providers/ChatGPT/Account` |
| NativeAgentProviderChatGPTText | ChatGPTTextProvider | `Providers/ChatGPT/TextProvider`, 모델만 |
| ChatGPTAgentFactory | 같은 type, module=ChatGPTAgent | `Agent/NativeAgentPackage/Packages/ChatGPTAgent`로 이동 |
| NativeAgentCapabilityChatGPTImage | ChatGPTImageCapability | `Agent/NativeAgentPackage/Packages/ChatGPTImageCapability` |
| AppleLocalAI / AppleLocalAICore 및 부속 API | 이름 유지, 이행 보류 | `MigrationHold/AppleLocalAI` |

## 기존 계약과 새 계약

| 유지하는 계약 | 새 투영 / 판단 |
|---|---|
| ModelClient | Runtime의 `ClientLanguageModel`이 descriptor/executor로 감싼다. 실제 loader/credential/native cancellation은 기존 owner 유지 |
| ModelClientWithOwnedInvocation | 명시적 cancel/waitForCompletion port 그대로 사용 |
| ModelRequest/ModelEvent/ModelTurn/AgentMessage | wire value를 유지. 별도 동등 schema를 추가하지 않음 |
| ModelProviderRegistry/Connector | host 선택/획득 API 유지. store가 대신 provider를 자동 고르지 않음 |
| ModelRuntime(client:) | 유지. `ModelRuntime(model:)`도 동일 admission/drain authority를 사용 |
| LocalBackend/ModelRuntimeAccess | resident ownership 및 owned/borrowed semantics 유지 |
| AppleLocalAISession structured/macros/audio/profile | façade와 동등하다고 주장하지 않음. 실제 consumer/native 검증 후 이행 판단 |

## 보존하는 관찰 가능한 계약

대화 commit에서 rich metadata를 보존한다. 생성 response message ID가 imported transcript ID와 충돌하지 않는다.
취소 중 drain failure를 CancellationError로 가려 borrowed close가 성공하는 경우를 차단한다.
Apple text 경로는 중간 system role을 재배열하지 않고 거부한다. byte limit의 임의 token 환산과 추정 stop reason을 제거한다.

새 façade는 source-shape 편의 범위이며 `@Generable`, `@Guide`, Apple 응답 generic type의 drop-in API가 아니다.
[소스 수준 public 선언 목록](verification/imported-baseline/public-api-snapshot.json)은 ABI/symbol graph 검증과 다르다.

이번 입력 경계 수정은 정확한 숫자 변환·진단 UTF-8 보존·취소 후 획득 정리·Hub 반환 계약 검증이다. public 선언과 resource/manifest 보존은 위 snapshot 및 [Current](IMPLEMENTATION_STATUS.md)를 따른다. source diff 검사는 ABI 안정성이나 Apple SDK API parity 검증이 아니다.
