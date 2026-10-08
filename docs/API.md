# Public API contracts

현재 module/product만 제공한다. 하위 버전 호환 wrapper, 이전 module alias와 데이터 마이그레이션 경로는 제공하지 않는다. 보관된 AppleLocalAI 및 과거 release 도구는 2026-10-07 사용자의 명시적 clean-break 요청으로 제거했다.

| 제품 | 계약과 소유권 |
|---|---|
| LanguageModelCore | request/event/turn/schema 값 |
| LanguageModelRuntime | 실행 admission/cancel/terminal/drain, ModelSession committed transcript |
| ModelArtifactStore / ModelHub | 검증한 artifact publication/lease, host가 선택한 provider 설치 |
| MLXProvider / MLXModelRegistry | 현재 MLX 라이브러리의 text/structured/tool adapter, 검증한 모델 catalog |
| LiteRTProvider / LiteRTEmbeddingProvider / EmbeddingCore | 독립 text/embedding owner, 검증된 모델 준비·lease, 순서 보존 일괄 임베딩, profile별 검색 인덱스 |
| LEAPProvider | 현재 LEAP 라이브러리의 text/voice adapter와 resident |
| AppleSystemModelProvider / FoundationModelsBridge | Apple OS gate를 지킨 text 계약 |
| NativeAgent / NativeAgentManager | 승인, durable effect와 Agent 조립 |
| ChatGPTAccount / ChatGPTTextProvider / ChatGPTImageCapability | 인증, 원격 text, 독립 image effect |

ModelClientWithOwnedInvocation의 events/cancel/waitForCompletion과 LocalBackend/ModelRuntimeAccess의 owned/borrowed 의미를 유지한다. ModelRuntime(client:)와 ModelRuntime(model:)는 동일 admission/drain owner를 사용한다. ClientLanguageModel은 필요한 executor projection이며 새 loader/history owner를 만들지 않는다.

대화 성공만 commit하고 rich metadata와 imported transcript identity를 보존한다. 취소와 drain 실패를 구분한다. 모델 tool suggestion은 실행 승인이 아니다. 이미지, ASK apply와 Agent 승인·effect receipt는 기존 별도 소유권을 따른다.

NativeLanguageModels와 FoundationModelsBridge는 Apple structured/macros/audio API의 drop-in replacement가 아니다. 이전 AppleLocalAI API는 이번 명시적 폐기 범위이며 동등성이나 자동 이행을 약속하지 않는다.

실제 선언은 해당 Sources와 [SPEC](SPEC.md), [ARCHITECTURE](ARCHITECTURE.md)가 소유한다. 실행 증거는 [현재 검증](verification/README.md)에서 범위별로 확인한다.

MapKitSearchToolService는 iOS/macOS 26 이상에서 location/address API를 사용한다.
LEAP background 다운로드는 현재 v2 session/cache만 사용한다. 이전 캐시·task 메타데이터를 자동 채택하지 않는다.

ModelClient 구현은 generate와 stream을 모두 제공한다. generate-only 자동 stream 경로는 제거했다.
사용자 정의 ChatGPTTransport는 실제 cancel/waitForCompletion을 가진 invocation을 구현해야 한다.
구형 기본 구현·호환 alias·마이그레이션은 제공하지 않는다. 기존 저장 schema·credential bytes는 이 폐기 범위의 변경 대상이 아니다.

ModelProviderConnector와 ModelProviderRegistry는 acquireRuntime만 제공한다. 반환되는 ModelRuntimeAccess가 owned/borrowed를 명시한다.
ClosureModelProviderConnector의 acquireRuntime closure도 ModelRuntimeAccess를 반환한다.
ModelHubInstaller.installAndLoad는 (model, access)를 반환하며 사용이 끝나면 access.release()를 호출한다.
makeRuntime(modelID:)·registry.makeRuntime(selection) 호환 API와 기본 ownership 추론 구현은 제거했다.
