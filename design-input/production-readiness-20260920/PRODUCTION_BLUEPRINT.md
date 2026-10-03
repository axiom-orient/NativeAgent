# NativeAI — Production Blueprint

## 1. 제품 정체성

**NativeAI = Swift 앱에서 여러 AI backend를 동일한 실행 규율로 사용하되, backend의 고유한 수명·권한·오류 의미를 숨기지 않는 composable runtime.**

NativeAI는 다음이 아니다.

- 모든 AI 기능을 하나로 합친 giant SDK
- provider 선택을 임의로 수행하는 global router
- ChatGPT 구독 인증 우회 계층
- Agent/Knowledge/이미지를 text model의 부속 기능으로 취급하는 umbrella API
- native SDK의 실제 종료를 stream EOF로 추측하는 abstraction

## 2. Target Architecture

```text
Host App
│
├─ Text Feature ────────────────┐
├─ Image Feature ───────────────┤
├─ Agent Feature ───────────────┤  explicit composition
└─ Knowledge Feature ───────────┘
             │
             ▼
┌──────────────────────────────────────────┐
│ LanguageModelCore                       │
│ request / event / turn / error / schema │
└─────────────────┬────────────────────────┘
                  ▼
┌──────────────────────────────────────────┐
│ LanguageModelRuntime                    │
│ admission / session / cancellation      │
│ producer completion / drain / reuse     │
└───────┬──────────────┬───────────────┬───┘
        │              │               │
        ▼              ▼               ▼
 Apple FM          MLX/LiteRT/LEAP   Cloud Text
 independent       independent        independent
 provider          provider           provider

Image capability ─────────────── separate contract
NativeAgent ──────────────────── separate effect authority
ASK ─────────────────────────── separate knowledge authority
MCP / OS tools ──────────────── optional adapters
```

### 의존 방향

- `Core`는 provider/runtime/Agent/ASK를 모른다.
- `Runtime`은 concrete provider/Agent/ASK를 모른다.
- provider는 Agent approval 또는 ASK journal을 소유하지 않는다.
- Agent는 model 실행을 호출할 수 있지만 model lifecycle을 재정의하지 않는다.
- ASK adapter는 Agent tool contract에 맞출 수 있지만 ASK canonical journal을 Agent DB로 대체하지 않는다.
- host만 provider selection, account selection, OS permission, feature enablement를 조립한다.

## 3. Public API 전략

### 3.1 공통 Text API

공통 API는 “모든 provider 기능의 최소공배수”가 아니라 **모든 provider가 정확히 지킬 수 있는 실행 계약**이어야 한다.

최소 계약:

```swift
public protocol LanguageModel: Sendable {
    func start(_ request: ModelRequest) async throws -> ModelInvocation
}

public struct ModelInvocation: Sendable {
    public let events: AsyncThrowingStream<ModelEvent, Error>
    public func cancel() async
    public func waitForCompletion() async throws
}
```

핵심 의미:

- `events` 종료 ≠ producer 종료
- `cancel()` 반환 ≠ remote/native effect rollback
- `waitForCompletion()` = 이 invocation이 소유한 하위 실행의 terminal settlement
- 성공 transcript commit은 `waitForCompletion`과 결과 의미가 일치할 때만 수행
- drain failure를 정상 cancellation로 바꾸지 않음

현재 저장소의 `ModelClientWithOwnedInvocation` 방향은 유지할 가치가 있다. 새 wrapper보다 이 계약을 모든 실제 provider가 끝까지 구현하게 만드는 것이 우선이다.

### 3.2 Image API

Image는 text event stream에 억지로 넣지 않는다.

```text
ImageRequest
→ validate
→ remote/local generation
→ byte/result receipt
→ artifact validation
→ durable publication
→ ImageResult
```

`generation success`, `download success`, `artifact publication`, `caller DB commit`은 별도 단계다. 각각 failure/partial-result를 구분한다.

### 3.3 Agent API

Agent public contract는 모델이 아니라 **operation** 중심이어야 한다.

```text
Intent
→ Plan
→ Approval Decision
→ Effect Reservation
→ Execute
→ Observed Result
→ Durable Receipt
→ Reconcile / Complete
```

모델의 tool call은 승인도, 실행 성공도 아니다.

### 3.4 Knowledge API

ASK는 다음 흐름만 책임진다.

```text
Source → Evidence → Canonical Knowledge → Plan → Dry Run → Apply → Receipt
```

Agent integration은 `ASKAgentTools` 같은 adapter에서만 연결한다.

## 4. Lifecycle — 상용 수준에서 반드시 고정할 상태

### 4.1 Invocation

권장 상태:

```text
created
→ admitted
→ running
→ cancelling? ─┐
→ settling     ◀┘
→ completed | failed | outcomeUnknown
```

금지:

- `isRunning + isCancelled + isFinished` bool 조합
- EOF 수신만으로 idle 처리
- cancel 호출 후 즉시 resident 해제
- late callback이 새 generation 상태를 덮어쓰기

### 4.2 Resident / Local backend

```text
unloaded
→ loading
→ ready
→ inUse(n)
→ draining
→ unloading
→ unloaded
```

필수 invariant:

1. load owner 하나
2. waiter 취소와 shared load 취소 분리
3. borrowed frontend cleanup은 resident unload 금지
4. final release만 unload 수행
5. unload 실패 시 reusable-ready로 복귀시키지 않음
6. model artifact lease와 resident lease를 별도 관리

### 4.3 Credential lifecycle

```text
signedOut
→ authenticating
→ authenticated
→ refreshing
→ authenticated
→ signingOut
→ signedOut
```

현재 저장소의 남은 위험처럼 `refresh Task`와 credential mutation이 actor reentrancy 동안 분리되면 안 된다.

상용 계약:

- credential generation/revision을 둔다.
- refresh 결과는 시작 revision과 현재 revision이 같을 때만 commit한다.
- signOut은 active refresh를 cancel한 후 **동일 drain receipt를 join**한다.
- 두 번째 signOut/access도 진행 중 credential mutation drain을 관찰한다.
- 사용자 Task cancellation이 credential cleanup cancellation과 동일하지 않다.

## 5. Provider 전략

### 5.1 Apple Foundation Models — Production 후보

Apple은 Foundation Models를 on-device, Private Cloud Compute, custom `LanguageModel`, Core AI/MLX 통합까지 확장하고 있다. Guided generation은 constrained sampling으로 Swift type 형태를 보장하며, tool calling과 token/context API가 제공된다.

권장:

- Apple provider는 Foundation Models native contract를 직접 사용.
- `@Generable`/guided generation은 provider 전용 기능으로 노출하거나 공통 structured-output capability가 실제로 정의될 때만 공통화.
- OS update마다 model이 바뀔 수 있으므로 prompt/version qualification을 OS build 기준으로 수행.
- availability는 compile-time SDK와 runtime model availability를 분리.
- PCC는 on-device와 다른 execution location/cost/quota/privacy 의미이므로 별 capability로 표시.

### 5.2 MLX — macOS/Apple silicon 고성능·실험 provider

MLX Swift는 Apple silicon을 위한 ML framework이며 lazy evaluation/CPU-GPU execution 특성이 있다. NativeAI에서는 research/provider 역할에 적합하다.

Production 조건:

- model artifact digest 고정
- tokenizer/model config 호환성 검증
- first-load / warm-load / cancel / OOM / unload 측정
- GPU memory 회수와 다음 generation reuse 확인
- 동시에 여러 모델 resident를 허용할지 policy 명시

### 5.3 LiteRT / LEAP — 독립 device provider

이 provider들은 Foundation Models나 MLX와 동일 API를 제공한다는 이유만으로 lifecycle 구현을 공유하지 않는다. vendor callback, native handle, binary artifact, thread ownership을 각각 qualification한다.

### 5.4 OpenAI cloud — 두 경로를 구분

#### A. OpenAI API provider

Production cloud text/image에 가장 명시적인 계약이다.

- Text/agentic request: Responses API
- Streaming: SSE
- long-running: background mode + resumable sequence cursor가 필요한 경우 사용
- Image: Images API 또는 Responses의 image generation tool

**iOS 앱에 OpenAI API key를 넣지 않는다.** OpenAI 공식 보안 가이드는 mobile/browser client에 API key를 배포하지 말고 backend에서 보관하라고 명시한다. 따라서 public App Store 앱이라면 최소 backend/BFF가 필요하다.

#### B. ChatGPT subscription / Codex

OpenAI는 Codex App Server를 product embedding 인터페이스로 문서화하며 ChatGPT login, thread/turn lifecycle, approvals, streaming agent events를 제공한다. stable API와 experimental API가 capability로 구분된다.

그러나 이것은 **Codex agent integration** 계약이다. 임의 iOS 앱의 generic ChatGPT text/image subscription endpoint 계약과 동일하지 않다.

권장:

- macOS host에서 Codex 기능: `CodexAppServerProvider`라는 별도 adapter로 분리 가능.
- stdio transport 우선; WebSocket은 공식 문서상 experimental이므로 production 기본값으로 삼지 않음.
- iOS generic ChatGPT subscription text/image: 공식 stable client contract가 확인되기 전 Production 미승격.
- 현재 내부 service-profile/pin 방식은 `ExperimentalChatGPTProvider`로 이름·배포 경계를 명확히 한다.

## 6. Capability 모델

provider 이름으로 기능을 추측하지 않는다.

```swift
struct ModelCapabilities: Sendable, Equatable {
    let text: Bool
    let streaming: Bool
    let structuredOutput: StructuredOutputSupport
    let tools: ToolSupport
    let visionInput: Bool
    let imageGeneration: Bool
    let offline: Bool
    let executionLocation: ExecutionLocation
}
```

단, capability type은 실제 분기 요구가 생긴 항목만 추가한다. future-proof enum 남발은 금지한다.

host selection은 다음과 같이 pure policy로 둔다.

```text
Requirement + AvailableProviders + UserPolicy
→ SelectionDecision
```

실제 provider load/network call은 selection mechanism과 분리한다.

## 7. Error contract

오류는 “provider 문자열 message”가 아니라 caller가 행동을 결정할 수 있는 최소 taxonomy가 필요하다.

```text
invalidInput
unavailable
unauthorized
authenticationExpired
busy
cancelled
rateLimited(retryAfter?)
network
providerRejected
artifactCorrupt
resourceExhausted
settlementFailed
outcomeUnknown
internalInvariant
```

원칙:

- provider 원문은 diagnostics에 별도 보관하고 public error에 secret/token/body를 그대로 노출하지 않음.
- `outcomeUnknown`은 retryable error가 아니다. 먼저 receipt/reconcile.
- post-commit local failure와 remote request failure를 같은 코드로 합치지 않음.

## 8. Persistence / Artifact

### Artifact publication

```text
incoming bytes
→ temp file
→ validate size/type/hash
→ fsync/close
→ atomic rename
→ metadata commit
→ published
```

모델 artifact:

- immutable digest identity
- source URL/revision/model id는 metadata
- bytes digest가 실제 identity
- partial download는 canonical 경로에 두지 않음
- lease 중 delete 금지
- crash 후 temp cleanup과 canonical verification 분리

Agent/ASK durable state:

- SQLite transaction 경계와 external effect 경계를 같은 transaction이라고 표현하지 않음
- effect 시작 전 durable identity 기록
- observed receipt commit
- restart 시 pending/unknown reconcile

## 9. Security / Privacy

### 기본 규칙

- mobile binary에 cloud API secret 금지
- tokens/credentials를 log, diagnostics bundle, persisted transcript에 저장하지 않음
- Keychain은 사용자 credential 저장 owner, in-memory token lease는 provider owner
- artifact/model download hash 검증
- external URL/path는 canonicalization + allow policy
- tool execution은 explicit approval policy
- MCP remote 연결은 TLS/auth/allowed tool list를 host가 설정

### Data classification

모든 request는 최소 다음 분류를 가질 수 있어야 한다.

```text
public
private-local
private-cloud-allowed
restricted-no-cloud
```

자동 cloud fallback은 이 policy를 통과하지 않으면 금지한다.

## 10. Observability

추상 `logger.info`가 아니라 한 invocation을 끝까지 추적한다.

필수 correlation:

```text
requestID
sessionID
invocationID
providerID
modelID
artifactDigest?
effectID?
```

측정:

- admission wait
- model load latency
- TTFT
- tokens/sec 또는 output throughput
- total latency
- cancel→settled latency
- memory before/peak/after
- artifact download/verify time
- remote retry count
- outcomeUnknown count

prompt, raw user text, token은 기본 telemetry에 넣지 않는다.

## 11. Test Architecture

### Layer 1 — Pure contract

- validation
- state machine
- selection policy
- transcript transition
- error mapping
- idempotency key

### Layer 2 — Deterministic adapter test

- controlled async producer
- callback order inversion
- cancel at every await boundary
- duplicate callback
- late completion
- partial output

### Layer 3 — Real local I/O

- URLSession loopback server
- filesystem crash/reopen
- SQLite reopen
- concurrent lease/remove

### Layer 4 — Native qualification

각 provider 실제 SDK/device/model에서:

```text
resolve → load → warmup → generate → stream
→ cancel → settle → reuse → shutdown → reload
```

### Layer 5 — Cloud qualification

실계정 staging에서:

```text
auth → request → stream → cancel
→ retryable error → auth refresh
→ background/resume(if supported)
→ logout → no stale credential reuse
```

### Layer 6 — Consumer qualification

실제 iOS/macOS app에서 import, composition, lifecycle, background/foreground, memory pressure, termination/relaunch를 검증한다.

Swift Testing은 parameterized test, concurrency, tags/conditional enablement를 지원하므로 provider/OS/device matrix를 테스트 metadata로 분리하는 데 적합하다.

## 12. Release / Package 정책

### 권장 배포 단위

최종 release repository는 다음처럼 **작은 독립 package + composition examples**가 적합하다.

```text
NativeAI/
  Model/
    LanguageModelCore
    LanguageModelRuntime
    ModelArtifactStore
    ModelHub
  Providers/
    AppleSystemModel
    MLX
    LiteRT
    LEAP
    OpenAIAPI          # 정식 API provider가 필요할 때
    CodexAppServer     # macOS/Codex 목적일 때
    ExperimentalChatGPT # 필요 시 별도 비안정 배포
  Agent/
    NativeAgent
    Integrations/...
  Knowledge/           # 가능하면 별도 repository/product
    ASK
  Examples/
    iOSHost
    macOSHost
  Qualification/
```

SwiftPM product는 consumer에게 공개되는 build artifact이므로 product 수를 capability 경계와 맞추되, target을 내부 책임마다 기계적으로 쪼개지 않는다.

### ASK 권장 위치

ASK는 NativeAI의 모델 runtime보다 독립 제품 성격이 강하다. 장기적으로는 별 repository/package collection로 분리하고 `ASKAgentTools`만 integration package로 연결하는 것이 dependency graph와 release cadence를 단순화한다.

## 13. 제거해야 할 것 / 유지해야 할 것

### 제거 후보 — 증거가 생긴 뒤

- `MigrationHold/*`: API parity + consumer migration + native qualification 완료 후 삭제
- 날짜성 REVIEW/HANDOFF: facts를 STATUS/PLAN/ADR로 흡수한 뒤 release branch에서 제거
- imported baseline verification logs: release evidence bundle 밖으로 이동
- production path에서 사용되지 않는 packaging helper/one-off migration script
- private/unstable ChatGPT endpoint를 production처럼 노출하는 wrapper

### 유지

- reproducible package/qualification script
- artifact hash/provenance checker
- boundary checker
- release manifest generator
- device qualification harness
- failure logs/evidence는 release artifact와 분리하여 보존

## 14. Definition of Production Ready

다음이 모두 참일 때만 provider/capability에 `Production` 표기를 붙인다.

1. public contract가 문서와 실제 declaration에서 일치
2. 모든 material input/output/effect/receipt owner 명확
3. cancellation과 completion 분리
4. resource lifecycle이 load→reuse→shutdown까지 실제 환경에서 증명
5. secrets가 client/log에 유출되지 않음
6. partial effect/outcomeUnknown recovery 정의
7. 실제 consumer app에서 재현 가능한 build/run
8. OS/device/model/API version matrix가 기록됨
9. 장애 시 silent fallback/fake success 없음
10. release artifact provenance와 SHA-256 존재

