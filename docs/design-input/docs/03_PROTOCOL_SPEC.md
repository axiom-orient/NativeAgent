# 03 — Language Model Contract Specification

## 1. Design goals

- iOS 17+
- vendor-neutral
- `Sendable` 중심
- model descriptor와 execution 분리
- invalid state 최소화
- explicit capability negotiation
- streaming/cancellation first
- Apple iOS 27 구조와 semantic alignment

## 2. Core protocols

아래 코드는 목표 contract를 설명하는 설계 스케치다. 실제 migration 시 기존 public API와 type 이름을 대조해 최종 확정한다.

```swift
public protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor
        where Executor.Model == Self

    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
    associatedtype Model: LanguageModel
        where Model.Executor == Self
    associatedtype Configuration: Hashable & Sendable

    init(configuration: Configuration) throws

    func prewarm(
        model: Model,
        transcript: ModelTranscript
    ) async throws

    func respond(
        to request: ModelGenerationRequest,
        model: Model,
        streamingInto channel: ModelGenerationChannel
    ) async throws
}
```

Apple과 동일하게 중요한 점은 **Model보다 Configuration이 executor reuse key에 가깝다**는 것이다.

## 3. Capabilities

```swift
public struct LanguageModelCapabilities: OptionSet, Sendable {
    public let rawValue: UInt64

    public static let toolCalling
    public static let guidedGeneration
    public static let reasoning
    public static let vision
}
```

규칙:

- capability는 truthful declaration이어야 한다.
- unsupported capability는 provider 내부 silent degradation이 아니라 runtime에서 명시적으로 거부한다.
- provider-specific option은 core capability와 분리한다.

## 4. Model descriptor

Model은 최대한 가볍게 유지한다.

포함 가능:

```text
model identity
capabilities
executor configuration
static metadata
```

포함 금지:

```text
mutable chat history
Agent state
approval state
long-lived task owner
UI state
```

## 5. Executor

Executor가 실제 mechanism owner다.

소유:

- vendor SDK translation
- tokenizer / request formatting
- native/server inference call
- incremental stream event publication
- provider-specific prewarm

소유하지 않음:

- Agent durable state
- knowledge authority
- Host provider fallback policy

## 6. Runtime / Session

`LanguageModelRuntime`은 Apple `LanguageModelSession`과 비슷한 역할을 가지지만 NativeAI 내부 contract에 맞춘다.

소유:

- request admission
- one active generation invariant
- executor lookup/reuse
- cancellation
- terminal event validation
- drain/join
- optional transcript container

핵심 invariant:

```text
accepted request
→ exactly one terminal outcome
→ all producer tasks drained
→ next request allowed
```

late success가 cancelled/failed invocation을 덮어쓰면 안 된다.

## 7. Executor store

권장 key:

```text
Executor Type + Executor.Configuration
```

같은 configuration은 같은 resident/executor를 재사용할 수 있다.

단 native resident lifetime과 wrapper lifetime은 구분한다.

```text
Session closes      != model weights unload
Request cancelled   != backend resident destroy
```

## 8. Errors

MECE taxonomy:

```text
ModelContractError
├─ unsupportedCapability
├─ invalidRequest
└─ unsupportedContent

ModelAvailabilityError
├─ unavailable
├─ assetsNotReady
├─ credentialMissing
└─ entitlementMissing

ModelExecutionError
├─ providerFailure
├─ decodingFailure
├─ contextExceeded
├─ rateLimited
└─ timeout

ModelRuntimeError
├─ concurrentRequest
├─ cancelled
├─ invalidTerminalSequence
└─ runtimeClosed
```

provider raw error는 evidence에 보존하되 public domain error와 분리한다.

## 9. Streaming

Event contract 예:

```text
.started
.textDelta
.reasoningDelta
.toolCallDelta
.usage
.completed
.failed
```

Terminal은 `.completed` 또는 `.failed` 하나다.

Cancellation은 Swift cancellation을 보존하고 provider-specific fake success로 변환하지 않는다.

## 10. Tool calling

Tool schema는 model transport contract다.

그러나 실제 effect 실행 권한은 NativeAgent가 소유한다.

```text
Model emits ToolCall
→ NativeAgent validates
→ approval policy
→ effect executes
→ ToolResult
→ model continuation
```

`LanguageModelRuntime`이 임의로 side effect를 실행하지 않는다.

## 11. Structured generation

Core contract에서는 schema requirement를 표현한다.

```text
requested schema
required capability = guidedGeneration
```

Apple `@Generable` macro와의 1:1 source compatibility는 `NativeLanguageModels` façade 책임이다.

## 12. Vision

Vision은 LanguageModel capability로 지원할 수 있다.

그러나 **이미지 생성**과 혼동하지 않는다.

```text
Vision input     = language model capability
Image generation = separate effect/provider
```
