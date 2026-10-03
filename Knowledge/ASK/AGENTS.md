# ASK repository work

## Read order

1. `README.md`
2. `docs/IDENTITY_AND_EVOLUTION.md`
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_STATUS.md` — 현재 구현과 미검증 범위
6. `docs/PLAN.md` — 남은 qualification만
7. 변경 대상 package의 `Package.swift`, public source와 관련 tests

runtime behavior와 reachable wiring이 문서·이름보다 우선한다. ASK는 agent/host-facing local-first knowledge SDK다. `ASKClient`는 정상 root command/query surface다. MCP, Apple provider, document/capture/tutor/wiki/UI는 독립적으로 선택하는 경계다.

## Change law

- source identity/version/range, canonical journal/receipt/CAS/replay와 명시적 proposal/decision을 보존한다.
- 각 material state/decision에는 scope별 authoritative owner 하나만 둔다.
- pure decision과 I/O effect를 구분한다.
- 실제 mutation footprint와 external input scope를 검증한다.
- stale/duplicate/cancelled result가 최신 state를 바꾸지 못하게 한다.
- partial/unknown outcome을 success나 safe retry로 평탄화하지 않는다.
- adapter가 domain authority를 소유하지 않는다.
- forwarding-only wrapper, dual implementation path, duplicate transition layer를 추가하지 않는다.
- 사용 흔적이 보이지 않는다는 이유만으로 public/optional consumer contract를 dead로 판단하지 않는다.

## Documentation

- `README.md`: SDK 진입점과 package 문서 지도.
- `docs/IDENTITY_AND_EVOLUTION.md`: 제품 목적과 보존 원칙.
- `docs/ARCHITECTURE.md`: package dependency, state owner와 I/O 경계.
- `docs/SPEC.md`: normative public contract.
- `docs/IMPLEMENTATION_STATUS.md`: 현재 구현·미검증 사실.
- `docs/PLAN.md`: 미완료 qualification만.
- `docs/ADR-*.md`: 지속되는 결정 이유.
- `Packages/README.md`: SwiftPM package/product catalog.
- `Verification/README.md`: 재현 가능한 test/qualification entrypoints.

API와 schema는 source가 정본이다. 사용자 문서는 호출 조건과 실패 의미를 설명하고, 구현 현황·계획 스냅샷을 복제하지 않는다. 안정된 계약이 바뀌면 해당 정본 한 곳을 갱신한다.

## Verification and release

가장 작은 관련 gate를 실행한다. Apple host gate는 `Scripts/`, exact-source regression harness는 `Verification/OwnerChecks`에 있다. owner harness 통과를 root/package release PASS로 확대 해석하지 않는다.

fixture, generated output, credential, user data와 process log를 source에 넣지 않는다. source archive는 public products, manifests/pins, licenses, scripts와 checked-in project assets를 보존한다.
