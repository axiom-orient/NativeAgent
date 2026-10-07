# NativeAgent

NativeAgent는 **provider-independent durable agent execution SDK**다. 모델·도구 실행을 승인·effect identity·persistent state·recovery와 연결하지만, 특정 provider·UI·계정·knowledge system을 core에 강제하지 않는다.

## Public layers

```text
Host
├─ AgentManager        optional managed composition / Soul / Skills
└─ Agent               durable execution kernel
   ├─ Domain
   ├─ Execution
   ├─ Store
   └─ ModelRuntime → ModelCore

Optional adapters
├─ ChatGPT Text / Image
├─ Foundation Models
├─ MLX / LEAP / LiteRT
├─ MCP / Web / Browser / OS tools
└─ consumer-owned ASK composition
```

## 패키지 진입점

이 폴더 자체가 Swift package다. `Package.swift`, `Sources/`, `Tests/`가 루트에 있다.
소비 앱은 이 폴더를 local package로 추가하고 `NativeAgent` product를 선택한다.
`NativeAgentManager`는 선택 product다. Core/Runtime은 workspace `Model/`, provider는 `Providers/`로 분리했다.
이 `Packages/`에는 선택형 Agent 어댑터만 둔다.
AppleLocalAI·ASK·어떤 Integration 프로젝트도 kernel 필수 dependency가 아니다.

```sh
swift build --target NativeAgent
swift test
```

전체 테스트는 `NaturalLanguage` 등 Apple framework가 있는 지원 환경에서 실행한다.
모델 공유는 외부에서 준비한 `ModelRuntimeAccess`를 주입한다. 새 façade는 `Model/NativeLanguageModels`다.
현재 concrete provider를 사용한다. 이전 AppleLocalAI API는 명시적으로 폐기했으며 하위 버전 호환이나 자동 이행은 제공하지 않는다.

## 사용 시작

- managed agent 조립: [`docs/AGENT_MANAGEMENT.md`](docs/AGENT_MANAGEMENT.md)
- provider 선택과 resource lifetime: [`docs/PROVIDERS.md`](docs/PROVIDERS.md)
- package catalog: [`Packages/README.md`](Packages/README.md)
- 실제 검증: [`docs/VERIFICATION.md`](docs/VERIFICATION.md)

Shared direct-provider local model은 workspace [`LocalBackend` architecture](../../docs/ARCHITECTURE.md)를 따른다. Manager는 `ModelRuntimeAccess`를 통해 owned/borrowed runtime cleanup을 구분하며 borrowed runtime을 operation 종료 시 unload하지 않는다.

## 실행 불변조건

- model/tool output은 approval을 대신하지 않는다.
- request 결정과 effect에 전달된 입력이 의미상 동일해야 한다.
- effect start, remote/native completion, durable commit은 별개다.
- cancellation은 rollback 또는 effect 부재 증거가 아니다.
- unknown outcome은 reconciliation 전 자동 재실행하지 않는다.
- provider credential/native resident는 Agent session store와 별도 owner다.

## Agent 작업 문서

- [`AGENTS.md`](AGENTS.md) — 수정 규칙.
- [`IDENTITY_AND_EVOLUTION`](docs/IDENTITY_AND_EVOLUTION.md) — 제품 정체성.
- [`ARCHITECTURE`](docs/ARCHITECTURE.md) — package/state owner.
- [`SPEC`](docs/SPEC.md) — public/runtime contract.
- [`IMPLEMENTATION_STATUS`](docs/IMPLEMENTATION_STATUS.md) — 현재 상태.
- [`VERIFICATION`](docs/VERIFICATION.md) — qualification.
- [`PLAN`](docs/PLAN.md) — 남은 작업.

과거 분석 스냅샷은 제거했다. runtime Markdown/skills/prompts는 제품 입력이므로 일반 문서 정리 대상으로 삭제하지 않는다.

## 배포와 현재 증거

이 subtree만 떼어 게시하지 않는다. 형제 Core/Runtime 상대 참조를 포함하는
[workspace 배포 계약](../../docs/PACKAGING.md)을 따른다.
기존 monolithic release script는 현재 graph에서 제거했다.
[현재 검증](../../docs/verification/README.md)과 [상세 분석](ANALYSIS.md)를 먼저 확인한다.
