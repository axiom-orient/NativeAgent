# Public API contracts

현재 module/product만 제공한다. 하위 버전 호환 wrapper, 이전 module alias와 데이터 마이그레이션 경로는 제공하지 않는다. 보관된 AppleLocalAI 및 과거 release 도구는 2026-10-07 사용자의 명시적 clean-break 요청으로 제거했다.

| 제품 | 계약과 소유권 |
|---|---|
| LanguageModelCore | request/event/turn/schema 값 |
| LanguageModelRuntime | 실행 admission/cancel/terminal/drain, ModelSession committed transcript |
| ModelArtifactStore / ModelHub | 검증한 artifact publication/lease, host가 선택한 provider 설치 |
| MLXProvider / MLXModelRegistry | 현재 MLX 라이브러리의 text/structured/tool adapter, 검증한 모델 catalog |
| LiteRTProvider / LiteRTEmbeddingProvider / EmbeddingCore | 현재 LiteRT 라이브러리의 독립 text/embedding owner와 임베딩 값 |
| LEAPProvider | 현재 LEAP 라이브러리의 text/voice adapter와 resident |
| AppleSystemModelProvider / FoundationModelsBridge | Apple OS gate를 지킨 text 계약 |
| NativeAgent / NativeAgentManager | 승인, durable effect와 Agent 조립 |
| ChatGPTAccount / ChatGPTTextProvider / ChatGPTImageCapability | 인증, 원격 text, 독립 image effect |

ModelClientWithOwnedInvocation의 events/cancel/waitForCompletion과 LocalBackend/ModelRuntimeAccess의 owned/borrowed 의미를 유지한다. ModelRuntime(client:)와 ModelRuntime(model:)는 동일 admission/drain owner를 사용한다. ClientLanguageModel은 필요한 executor projection이며 새 loader/history owner를 만들지 않는다.

대화 성공만 commit하고 rich metadata와 imported transcript identity를 보존한다. 취소와 drain 실패를 구분한다. 모델 tool suggestion은 실행 승인이 아니다. 이미지, ASK apply와 Agent 승인·effect receipt는 기존 별도 소유권을 따른다.

NativeLanguageModels와 FoundationModelsBridge는 Apple structured/macros/audio API의 drop-in replacement가 아니다. 이전 AppleLocalAI API는 이번 명시적 폐기 범위이며 동등성이나 자동 이행을 약속하지 않는다.

실제 선언은 해당 Sources와 [SPEC](SPEC.md), [ARCHITECTURE](ARCHITECTURE.md)가 소유한다. 실행 증거는 [현재 검증](verification/README.md)에서 범위별로 확인한다.
