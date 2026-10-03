# Host 통합 — AgentManager

이 문서는 소비 앱 개발자의 설정·호출·운영 절차를 설명한다. public contract는 [SPEC](SPEC.md), dependency와 state owner는 [ARCHITECTURE](ARCHITECTURE.md), 실환경 검증 절차는 [QUALIFICATION](QUALIFICATION.md)을 따른다.

아래 예시의 provider 준비와 계정·권한은 host가 제공한다.

## 조립과 시작

Host는 사용할 connector를 명시적으로 구성하여 `ModelProviderRegistry`에 등록하고, `AgentDataStore`, tool packs/executors, 승인 정책을 `AgentManager`에 제공한다. `createAgent`의 provider ID는 등록되어 있어야 한다. 모델 준비·로그인·OS 권한은 해당 provider/host에서 먼저 처리한다.

다음은 이미 구성한 registry와 유효한 selection을 받는 호출 예시다. 특정 계정·모델을 임의로 선택하지 않는다.

```swift
import NativeAgent
import NativeAgentManager
import LanguageModelRuntime

func makeManager(
  dataStore: AgentDataStore,
  providers: ModelProviderRegistry,
  selection: ModelProviderSelection
) async throws -> AgentManager {
  let manager = AgentManager(dataStore: dataStore, providers: providers)
  _ = try await manager.createAgent(
    id: "primary", name: "Primary", provider: selection,
    soul: "근거와 권한을 확인하고, 불확실한 실행 결과는 그대로 보고한다."
  )
  return manager
}
```

이 예시는 초기 생성용이며 idempotent upsert가 아니다. 기존 Agent는 `definition`/`handle`로 열고, `ManagedAgent.run`으로 새 세션을 시작한다. 기본 approval은 `.denyAll`, managed script runner는 disabled다. 필요한 정책·runner를 host가 명시적으로 주입하기 전에는 실행 권한을 부여하지 않는다. 실제 API는 [AgentManager.swift](../Sources/NativeAgentManager/AgentManager.swift)와 같은 파일의 `ManagedAgent`가 정한다.

## 데이터 root와 쓰기 경계

```text
NativeAgent/
├── native-agent.sqlite3
├── sessions/
└── agents/<agent-id>/
    ├── agent.json
    ├── SOUL.md
    ├── RESPONSE.json
    ├── USER.md
    ├── MEMORY.md
    ├── skills/
    └── config/skills/state.json
```

이는 기본 배치의 상대 구조다. host가 정한 `AgentDataStore` root를 사용하며 credential은 이 root에 넣지 않는다. 공개 Manager/ManagedAgent API로 Agent 문서를 수정한다. `AgentWorkspace`의 process mutex와 `.agent-mutation.lock`은 협조하는 writer 사이의 managed 문서 변경을 직렬화한다. 이 lock을 Skill root 전체의 lock으로 해석하지 않는다.

Soul은 안정된 identity/행동 원칙, USER는 사용자 지시, MEMORY는 `.localCuratedMemory`에서만 사용하는 작고 명시적으로 관리한 사실·결정이다. `.externalKnowledgeBase`에서는 MEMORY 파일 생성·읽기·쓰기·prompt projection을 허용하지 않으며 facts의 truth는 외부 지식 owner에 둔다. transcript의 정본은 SQLite다. 모델/tool 결과는 자동으로 `MEMORY.md`에 승격되지 않는다. 기본 경로는 advanced `NativeAgentMemory`가 아니다. 크기·경로·ID 한도는 [AgentWorkspace.swift](../Sources/NativeAgentManager/AgentWorkspace.swift)의 원본을 따른다.

`RESPONSE.json`은 캐릭터 프로필·언어 fallback·지침 크기 한도를 저장한다. 새 Agent에서 soul을 생략하면 `AgentSoul.default`를 사용한다. `responseConfiguration` / `setResponseConfiguration`으로 응답 설정을 관리하며, 언어와 윤문 모드는 각 사용자 메시지에 지정한다. iOS 전용 스킬과 Swift 검사 API는 [NATIVE_WRITING](NATIVE_WRITING.md)을 따른다.

## 세션 지속과 변경

새 세션에는 Agent ID, provider/model, Soul SHA-256, selected Skill tree SHA-256을 고정한다. `selectProvider`는 새 세션에 적용되며 기존 세션의 provider/model을 바꾸지 않는다. Soul/selected Skill 변경 후 기존 세션을 계속하면 drift를 거부한다. USER/MEMORY는 turn 사이에 갱신할 수 있다. 자동 provider fallback은 없다.

새 managed 세션에는 캐릭터·응답 설정·정책 revision의 SHA-256도 고정한다. 설정 변경 후 기존 세션 재개나 필수 식별자가 없는 세션은 `AgentResponseError.snapshotChanged`로 거부한다. 저장된 `RESPONSE.json`은 필수이며 누락·손상 시 기본 설정으로 대체하거나 파일을 재생성하지 않는다.

선택 Skill은 local materialization과 검증을 거친 immutable tree snapshot에서 읽는다. name/description catalog와 본문·resource 로드는 구분한다. Skill 문서/metadata는 권한을 부여하지 않는다. selected Skill이 있으면 해당 runtime의 canonical tool-call 지원이 필요하다. text-only adapter를 조용히 대신 사용하지 않는다.

`skillLibrary(agentID:)`로 받은 서로 다른 handle이 같은 standardized root를 사용하면 process-local `SkillWorkspaceAccessCoordinator`를 공유하므로 read·mutation·recovery·secret access가 직렬화된다. 외부 임의 writer와 동시 multi-process Skill 편집을 보장하지 않는다. 필요한 host는 Skill root의 single-writer 경계를 별도로 조정한다. Skill secret은 state transaction과 별도다. FileSkillSecretStore는 private sibling staging file을 완성한 뒤 atomic replace하며 교체 실패 시 기존 document를 보존한다. Apple 기본 Keychain은 service/skillName 범위이며 Agent root별 격리를 뜻하지 않는다.

## 실행·검토·복구

```text
run/send/resume → pinned assembly → Agent → model/tool effect → durable result
inspection/reconciliation/claim-release recovery → ownership check → durable store
```

모델 없이 `Agent.executeTool`을 호출해도 같은 schema·approval·effect 경로를 통과한다. 다만 **Manager의 `executeTool`은 pinned provider assembly를 요구한다**. 추론 생략과 provider 불필요는 다르다.

pending approval/model/tool effect, artifact/effect 읽기, reconciliation, execution-claim release 복구는 provider를 조립하지 않는 경로가 있다. `resolveToolEffect(..., continueRunning: true)`는 effect 조정을 먼저 확정하고, 그 뒤 continuation을 위해 provider 조립을 시도한다. continuation 오류가 났다고 앞의 조정까지 미반영된 것으로 처리하지 않는다.

모르는 외부 효과는 확인·조정 전 자동 재실행하지 않는다. time/signal wait의 깨우기와 background task 등록은 host 책임이다. Manager는 호출 뒤 자신이 만든 ModelRuntime을 shutdown하지만 LEAP/MLX의 shared resident까지 해제하는 owner는 아니다. 해당 host runtime의 unload는 [PROVIDERS](PROVIDERS.md)를 따른다.
