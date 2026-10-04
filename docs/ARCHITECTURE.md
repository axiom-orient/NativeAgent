# NativeAI — ARCHITECTURE

확정 경계와 소유권을 정의한다. 실제 graph·충족 상태·결함은 [Current](IMPLEMENTATION_STATUS.md)와 연결된 ANALYSIS를 따른다.

## Composition·의존 방향

```text
Host composition
├─ NativeLanguageModels → ModelSession → ModelRuntime → LanguageModelCore
├─ NativeAgent → LanguageModelRuntime / LanguageModelCore
│  └─ 선택 AgentManager / Skills / Memory / Goals / Evolution / Consensus / OS tools
├─ ASK → 자체 knowledge/source/evidence/application packages
│  └─ 선택 ASKTutor / document / capture / UI / MCP / Apple adapter
└─ 선택 integration adapters
   ├─ ChatGPTAgent / ChatGPTImageCapability → Agent + 해당 ChatGPT service
   ├─ ASKAgentTools → NativeAgent tool contract + ASKClient
   └─ NativeAgentMCP → Agent + external MCP

Providers → Core/Runtime + vendor SDK / ModelHub / ModelArtifactStore
FoundationModelsBridge → Core + Apple FoundationModels
Qualification → 필요한 production products (반대 의존 금지)
```

루트는 범용 package collection이다. Root manifest는 기존 Agent/model/provider/account/image/knowledge/UI target을 각각 concrete product로 공개한다. 앱 이름의 product나 조합 target을 두지 않는다. 앱은 필요한 product를 선택하고 구체 모듈을 직접 import하며 host composition을 소유한다. Core/kernel의 의존 방향과 concern별 state owner는 배포 방식과 무관하게 유지한다.

Agent kernel은 concrete provider·ASK·façade를 import하지 않는다. Providers는 Agent 승인/저장소를 import하지 않는다. same-process Swift composition에 새 HTTP/MCP gateway나 global manager를 끼우지 않는다. `MigrationHold`는 활성 graph 밖의 보존 API다.

## Authoritative owner

| concern·scope | owner | 소유하지 않는 것 |
|---|---|---|
| request/event/schema/descriptor | LanguageModelCore 값 계약 | credentials, run state, DB |
| 한 run admission/terminal/drain | ModelRuntime | 대화 전체, Agent 승인, native unload 정책 |
| 한 대화의 committed history | ModelSession; SessionLedger는 pure transition | 다른 session/history, provider 수명 |
| host config별 runtime 재사용 | ModelExecutorStore | 전역 자동 dedup/병렬 pool/provider 선택 |
| 직접 native backend load/final release | LocalBackend + 해당 provider resident | Agent operation cleanup |
| credential/transport/native mechanism | 구체 provider | Agent/ASK domain authority |
| Agent 승인·effect identity·복구 | NativeAgent domain/execution | knowledge 정본, remote rollback 보장 |
| session/effect durable refs | Agent Store | 외부 서비스 전체 transaction |
| source/knowledge/receipt/journal | ASK의 domain별 owner | Agent execution approval |
| artifact bytes/lease/publication | ModelArtifactStore 또는 해당 artifact adapter | 모델 선택·대화 transcript |
| UI·계정 선택·권한·서비스 조립 | host | 공통 SDK가 임의 결정하지 않음 |

## 실행과 상태

`Input → validate → decision/state → effect → observed result → state/commit → output`을 따른다. Agent model 실행은 reserve→durable effect-start→start 순서다. tool 실행은 schema/approval/ledger→effect-start→execute→observed result→commit 순서다.

ModelSession은 pending generation identity와 committed transcript를 구분한다. 취소/실패는 pending을 rollback하고 성공에만 commit한다. Runtime event terminal과 native settlement는 별도이며 provider completion을 기다려야 한다. 실패한 drain을 idle/cleanup 성공으로 바꾸지 않는다.

ModelExecutorStore는 executor type+configuration으로 runtime을 재사용한다. 다른 credential/resident binding을 model 이름만으로 합치지 않는다. 동일 binding은 한 admission lane을 공유한다. caller의 직접 shutdown 뒤 자동 재생성/재시도는 별도 승인 없는 정책으로 추가하지 않는다.

## 수명·동시성·복구

host는 resident당 하나의 LocalBackend를 만들고 필요한 frontend에 같은 runtime을 borrowed로 준다. intake 중단→자기 run 취소→producer/native drain→소유 resource release 순서다. borrowed session/Agent cleanup은 host resident를 unload하지 않는다. shared load의 한 waiter 취소가 다른 caller의 load를 취소하지 않게 한다.

actor는 실제 공유 mutable state에 사용하고 Ledger/plan/schema는 pure value로 둔다. OS/SDK callback은 해당 adapter의 synchronization 계약을 따른다. cancellation은 협력적 signal이며 join/원격 rollback/commit 취소와 동일하지 않다.

Hub install, image generation, ASK apply처럼 write 경계를 지난 후에는 관찰한 receipt를 보존한다. 후속 취소/저장 실패를 효과 부재로 재분류하지 않는다. outcomeUnknown은 증거 확인·조정 없이 자동 replay하지 않는다.

## Persistence와 권한

Agent SQLite transaction, artifact filesystem publication, ASK journal, 원격 service는 별도 transaction domain이다. revision/CAS, identity/digest, explicit receipt를 연결하며 하나의 global transaction이라고 주장하지 않는다. source/evidence index와 UI projection은 canonical journal을 대체하지 않는다.

ASK process-wide mutation lane은 같은 process에서 겹치는 resource roots의 동시 쓰기를 조정한다. cross-process lock·journal recovery는 각 persistence owner의 계약이다. 모델에게 path/approval writer 권한을 주지 않고 고정된 command/actionID를 adapter로 전달한다.

## 선택 기능·확장 조건

Text와 Image는 Account를 공유할 수 있지만 서로를 필수 의존하지 않는다. Image·MCP·ASK/Agent integration은 host가 명시 등록한다. FoundationModelsBridge는 Apple→공통 모델의 단방향 text projection이다.

새 adapter는 source contract, activation 조건, resource owner, cancellation/completion, partial effect, capability declaration, 실제 qualification 경계를 제시해야 한다. public API 이름 이동은 [API_MAPPING](API_MAPPING.md), 지속적인 결정은 [ADR](adr/0005-runtime-and-effect-boundaries.md)을 따른다.

## ChatGPT의 완료 경계

`ModelClientInvocation → ChatGPTSSEInvocation → ChatGPTTransportInvocation`은 서로의 하위 작업을 소유하고 join하는 handle이다. 별도의 runtime/queue가 아니다. URLSession task-complete와 session-invalidated receipt가 모두 관측되어야 transport completion이 확정된다. credential/catalog 공유는 Account/TextSession의 기존 책임이며 Image와 Text를 연결하는 실행 dependency가 아니다.

custom transport가 completion을 제공하지 않으면 관리형 서비스는 I/O 전 invalidConfiguration으로 거절한다. 기존 stream-only 직접 API는 유지한다. 원격 outcomeUnknown과 로컬 drain 실패는 서로 다른 의미를 보존한다.


## Account/producer 소유권 보강

Account actor는 credential/authorization generation·admission·auth Task만 제어한다. `ChatGPTCredentialStoring` → Apple Keychain, `ChatGPTSignInSession` → native PKCE/listener의 I/O 경계를 사용한다. 테스트 전용 port는 production fallback이 아니다.

Transport invocation의 events/cancel/waitForCompletion을 Account/Text/Image가 공유한다. Text는 준비 단계의 drain 실패까지 producer에 전달한다. Runtime의 control/error와 Image shared gate, Account의 identity별 failure roots가 실제 실패 invocation을 유지한다. primary admission 상태의 owner를 추가로 만들지 않으며 resource retention과 policy state를 구분한다.

상세 변경·native qualification은 [최신 리뷰](production/IMPLEMENTATION_REVIEW.md)를 따른다.

## Loopback callback — 순수 상태와 I/O

```text
Account authorization epoch
  → ChatGPTSignInSession (PKCE / selected redirect / native server handle)
    → ChatGPTLocalhostCallbackServer (one private serial queue)
      → ChatGPTCallbackRequest.parse(bytes) → incomplete | invalid | callback(URL)
      → ChatGPTCallbackState transition → cancel/send/receive effects
      ← NWListener / NWConnection / I/O receipts with operation identity
    ← callback result + local drain result
  → Account state/code/token validation → credential commit OR retained failure
```

`ChatGPTCallbackState`만 resource admission과 completion 사실을 소유한다. OS 호출·시계·identity 생성은 없다. connection별 submitted I/O token은 최대 하나이며 정확한 token의 receipt만 반영한다. adapter의 mutable state와 Network callback은 하나의 serial queue에 머문다. caller별 cancellation flag는 등록 이전 취소 race만 닫으며, UUID는 관계없는 caller의 취소를 막는다.

listener 종료와 accepted connection의 종료는 다르다. stopping 중 거절한 connection도 cancelled와 pending I/O receipt가 모두 올 때까지 보존한다. 선택된 HTTP response는 다른 connection을 drain하는 동안 마칠 수 있다. send completion은 원격 전달이나 OAuth 성공의 증명이 아니다. 처음 결정한 callback 결과와 별도의 sticky drain failure는 서로 다른 사실이다.

| 값 분류 | authoritative owner / 예 | 변경 의미 |
|---|---|---|
| Constant | `ChatGPTProtocolProfile.registeredCallbackPorts`, redirect path | 등록된 wire identity; 조절 가능한 timeout 아님 |
| Policy | `ChatGPTCallbackPolicy`: 16 KiB request, 8개 admission, 5초 shutdown | 내부 안전 결정; 초과/미완료는 명시적 실패 |
| Configuration | 선택된 `port`/`redirectURI`, host credential namespace | 한 인스턴스의 immutable binding |
| Settings | host의 제품/model 선호 | callback mechanism에 새 설정을 넣지 않음 |
| Feature Flag | 추가 없음 | compatibility path/silent fallback 없음 |
| State | ledger phase/entries/I/O UUID, waiter/outcome/drain failure | 관측된 수명 사실; configuration으로 저장하지 않음 |

admission 상한은 처리 요청 수를 제한하지 kernel resource나 이미 enqueue된 accept 전체의 절대 상한을 보장하지 않는다. accepted handle은 모두 receipt가 필요하다. 5초 경과는 미증명 종료 실패이지 release 성공이 아니다. 늦은 receipt가 resource를 정리해도 실패를 지우거나 Account admission을 자동 재개하지 않는다. native 실행은 Apple qualification 대상이다.
