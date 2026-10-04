# AGENTS.md — NativeAgent

현재 작업 기준: [구현·리뷰](docs/production/IMPLEMENTATION_REVIEW.md), [요구사항](docs/production/REQUIREMENTS.md), [출시 gate](docs/production/QUALIFICATION.md). `docs/verification/current`의 실제 명령·source hash만 현재 실행 증거로 사용한다. imported-baseline/design-input은 과거 증거다. Account/Text/Image의 leaf tests도 직접 실행한다. 전체 release 상태는 BLOCKED이며 native/live/consumer gate를 fixture로 대체하지 않는다.

## 먼저 읽기

[정체성](docs/IDENTITY_AND_EVOLUTION.md) →
[구조](docs/ARCHITECTURE.md) → [계약](docs/SPEC.md) →
[현재 상태](docs/IMPLEMENTATION_STATUS.md) → [PLAN](docs/PLAN.md).
수정할 하위 패키지의 AGENTS/README/manifest/source/tests를 함께 읽는다.
[설계 원문](docs/design-input/README.md)은 입력의 고정 스냅샷이며 구현 완료 증거가 아니다.

## 진실과 변경

사용자 요구 → 실제 연결된 코드/상태/I/O → 테스트·설정·manifest → 실제 실행 결과 → 문서.
성공/실패 판단은 명령의 exit와 로그로 증명한다. 실행하지 않은 native 기능을 완료로 보고하지 않는다.
fixture는 계약 반례 검증용이다. 실제 inference/account/OS 권한의 증거로 사용하지 않는다.

상태의 authoritative owner는 concern마다 하나다. Pure transition과 effect를 분리한다.
불필요한 protocol/target/actor/manager를 추가하지 않는다. 기존 public contract는 명시된
[API 매핑](docs/API_MAPPING.md) 외에 근거 없이 바꾸지 않는다.
Resources/PromptSources/SkillSources/LICENSE/NOTICE는 단순 문서가 아니라 제품 입력이다.

## 고정 경계

- Repository-root `Package.swift`는 범용 Agent/model/account/provider/image/knowledge/UI
  product를 각각 공개한다. 소비 앱은 필요한 concrete product만 선택하고 각 state
  owner를 그대로 사용한다. 앱 전용 배포 product·target·facade를 추가하지 않는다.
- Core는 request/event/schema 값 계약만 소유한다. Runtime은 실행 수명, Agent는
  승인·effect 상태, provider는 외부 I/O, SDK UI는 표현을 소유한다. 앱 조립은 소비
  앱에 남으며 Core/kernel에서 provider·knowledge·UI를 역으로 의존하지 않는다.
- Root package/repository identity는 `NativeAgent`다. Nested
  `Agent/NativeAgentPackage` package identity와 충돌하지 않게 유지한다.
- Agent root는 `Agent/NativeAgentPackage`; 모델 계층은 `Model`이다. 옛 `NativeAgent/Packages` 사본을 재생성하지 않는다.
- Agent kernel의 로컬 package 의존성은 Core와 Runtime뿐이다. Providers/ASK/façade를 import하지 않는다.
- Provider는 Agent 실행·승인·저장소를 import하지 않는다. 선택형 Agent 어댑터만 양쪽 계약을 연결한다.
- `ModelRuntime`: admission/cancel/terminal/drain. `ModelSession`: 한 대화의 committed transcript.
- `ModelExecutorStore`: host가 소유하는 reuse 범위. `LocalBackend`: 기존 direct provider resident의 load/release.
- 동일 native handle을 두 owner가 해제하지 않는다. borrowed close는 resident unload가 아니다.
- `FoundationModelsBridge`: Apple 27 → NativeAI 단방향, 현재 text-only. 역방향 bridge/매크로 parity는 범위 밖이다.
- `NativeLanguageModels`: immutable façade. 별도 Task store/history/loader/provider routing을 만들지 않는다.
- `ASKAgentTools`: ASK plan/dryRun/query/apply를 투영한다. 승인과 durable effect는 Agent, 지식/receipt는 ASK가 소유한다.
- 이미지 생성은 텍스트 provider의 capability가 아니라 별도 선택형 effect다.
- 활성 package는 `MigrationHold`에 의존하지 않는다. 실제 consumer/native parity gate를 충족하기 전 보존된 public API를 삭제하지 않는다.

## 실패·동시성

`Input → validate → state transition → effect → result → state/output`를 추적한다.
취소 요청/EOF/native join/commit/resident release는 각각 다른 경계다.
종료는 intake 중단 → 자신의 실행 취소 → drain 증명 → 소유한 resource 해제 순서다.
미증명 drain은 실패/격리로 남기며 cleanup을 성공 처리하지 않는다.
late/duplicate/stale 결과가 현재 상태를 덮어쓰지 않도록 generation/identity를 검증한다.
unknown effect outcome은 확인 전 자동 replay하지 않는다. 자동 fallback·silent recovery·fake success 금지.

## 검증과 문서

```sh
python3 tools/verify-portable.py
python3 tools/verify-native-kernel.py
python3 tools/verify-chatgpt-wire.py
python3 tools/check-boundaries.py
python3 tools/check-documents.py
```

ASK 변경은 실제 ASKAgentTools 테스트, Apple 변경은 SDK 26/27 compile/link/device matrix를 추가한다.
미실행은 NOT_RUN, 환경으로 실패한 명령은 exit/log와 SKIPPED_ENV를 함께 남긴다.
verification/current의 source hash와 실제 명령 결과만 이번 증거다. 이전 입력의 검증 기록을 현재 PASS로 승계하지 않는다.
`MigrationHold/NativeAgentRelease`의 옛 release script는 현재 배포 도구가 아니다.

README=승인 안내·저작권, AGENTS=시작/탐색·운영 규칙, IDENTITY=목적/불변/발전, ARCHITECTURE=경계/owner,
SPEC=규범, IMPLEMENTATION_STATUS=현재 사실, PLAN=남은 작업,
분석 단위 ANALYSIS=세부 경계/근거/비판적 검토, verification=실행 증거로 책임을 나눈다.

## 현재 ChatGPT completion 규칙

`events + cancel + waitForCompletion`을 ModelClient→SSE→transport까지 유지한다. HTTP EOF와 task completion과 session invalidation은 서로 다르다. 두 native callback을 확인하기 전에 transport 참조를 놓거나 idle로 보고하지 않는다. legacy custom transport의 completion을 EOF로 합성하지 않는다. 인증 공유 수명은 개별 invocation과 다르다.

독립 source bundle은 `tools/package-closure.py`로 실제 manifest 의존성만 추출한다. manifest/pin을 다시 쓰지 않는다. `tools/test-package-closure.py`와 추출 후 소비 패키지 빌드를 검증한다. 최신 상태는 [구현 리뷰](docs/production/IMPLEMENTATION_REVIEW.md), [HANDOFF](HANDOFF.md)다. 날짜성 REVIEW는 이전 입력 기록이다. imported-baseline은 이번 PASS가 아니다.

## Loopback callback의 현재 경계

`ChatGPTCallbackState`만 listener/connection/I/O receipt를 소유한다. `ChatGPTLocalhostCallbackServer`는 전용 serial queue의 Network adapter이며 MainActor나 callback별 Task hop을 다시 추가하지 않는다. 취소 후 accepted connection과 submitted I/O까지 join한다. drain deadline은 성공이 아니라 sticky failure이며 기존 Account failure owner가 보존한다.

`ChatGPTCallbackRequest`는 incomplete와 invalid를 구분한다. OAuth state/code/token의 승인 owner는 Account다. callback 수신의 HTTP 200을 로그인 성공으로 표시하지 않는다. Native socket 테스트는 Account의 `CallbackNativeTests`에 있다. Linux에서 제외된 suite는 NOT_RUN이며 pure ledger 테스트로 대체 인증하지 않는다.
