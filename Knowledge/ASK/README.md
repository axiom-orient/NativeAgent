# ASK

ASK는 문서 source, 원문 근거, 승인 지식과 journal을 관리하는 독립 headless knowledge SDK다. NativeAgent는 선택 consumer이며 필수 dependency가 아니다. 앱의 UI, 계정, OS 권한, storage placement, egress와 composition root는 소비자가 소유한다.

## Consumer 시작점

SwiftPM consumer는 [ASK package manifest](Package.swift)와 필요한 optional packages를 직접 선택한다. root product `ASK`의 public entrypoint는 `ASKClient(configuration:)`이며 `plan`, `dryRun`, `apply`, `query`, `withWorkspaceMaintenance`를 제공한다. 호출 타입과 오류는 [ASKTypedContracts.swift](Sources/ASK/ASKTypedContracts.swift)와 [규격](docs/SPEC.md)을 따른다.

선택 가능한 package/product와 서로 다른 책임은 [package catalog](Packages/README.md)에 정리했다. parser·document·capture·wiki·tutor·MCP·Apple adapter를 모두 함께 의존할 필요는 없다.

## 핵심 경계

- 원문 identity/version/evidence와 canonical knowledge journal은 ASK가 소유한다.
- root query는 workspace나 presentation을 몰래 만들거나 복구하지 않는다.
- 한 workspace의 root writes는 host가 조정하는 single-writer 경계를 따른다.
- read permission, external model egress와 knowledge approval은 별도다.
- NativeAgent와의 same-process composition은 consuming application의 책임이다.

## 검증 harness

`Verification/`의 consumers와 `Scripts/`는 SDK를 독립적으로 검증하는 도구이며 제품 앱이 아니다. 실행 가능한 entrypoint와 corpus/device 전제는 [Verification 안내](Verification/README.md), exact-source regression 절차는 [OwnerChecks](Verification/OwnerChecks/README.md)를 참조한다. harness 실행과 실제 model/device/network qualification은 별도 경계다.

ASK package의 platform·toolchain·dependency pins는 각 package manifest와 lockfile에 따른다.

## 정본 문서

[정체성과 발전 원칙](docs/IDENTITY_AND_EVOLUTION.md) · [SPEC](docs/SPEC.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) · [현재 구현·상세 분석](docs/IMPLEMENTATION_STATUS.md) · [남은 PLAN](docs/PLAN.md)

[상세 ANALYSIS](ANALYSIS.md)에서 실제 caller/flow/owner와 미검증 범위를 확인한다. 현재 source의 실행 범위를 넘어 과거 qualification을 승계하지 않는다.
