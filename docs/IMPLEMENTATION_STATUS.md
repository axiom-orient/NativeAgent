# NativeAgent — IMPLEMENTATION_STATUS

## 메인 통합 · 2026-10-08

메인의 현재 라이브러리와 EmbeddingGemma 2 경로에 기존 저장·복구 개선을 통합한다.
Agent 최종 응답·완료 receipt·continuation을 한 저장 transaction으로 처리하고,
SQLite 파일 생성권, artifact sync/dedup, LEAP 설치·콜백의 작업 ID 소유권을 보강했다.
Context/Memory/Tutor/HWP/PDF 입력과 정리 실패를 검증한다.
MapKit은 OS 26의 location/address API를 사용한다.
LEAP background cache/session은 현재 v2만 사용하며 이전 메타데이터 채택·마이그레이션은 없다.

최종 명령·입력 hash·한계는 [메인 통합 검증](verification/current/main-consolidation-20261008/REPORT.md)이 소유한다.
아래 과거 기록은 당시 source의 결과이며 현재 source의 PASS로 합산하지 않는다.

## 이전 구현 기록

## 결론과 범위

**Callback과 ModelHub identity/validation의 구현·refactor 및 가능한 로컬 검증은 완료했다. Production release는 Apple/native/live gate 때문에 BLOCKED다.** 입력 `NativeAI-Production-Refactored-20260920(1).zip`의 1,824개 파일을 기준으로 보존을 대조한다. 53개 manifest/product/dependency pin은 변경하지 않았다. 전체 파일을 수작업으로 정독했다는 주장은 하지 않는다. package graph·Swift syntax 전수 검사와 callback/auth/consumer의 reachable 경로 검토를 구분한다.

이번 source·리뷰는 [구현 리뷰](production/IMPLEMENTATION_REVIEW.md), 실제 명령/exit/hash는 [검증](verification/README.md), 남은 native gate는 [PLAN](PLAN.md)이 정본이다. 이전 Account/Runtime/Image 수정과 과거 1,063개 테스트 수치는 입력에서 보존한 이력이며 이번 수치가 아니다.

## 프로젝트·상세 분석 색인

| material unit | 상세 정본 |
|---|---|
| LanguageModelCore | [ANALYSIS](../Model/LanguageModelCore/ANALYSIS.md) |
| LanguageModelRuntime·대화 façade | [ANALYSIS](../Model/LanguageModelRuntime/ANALYSIS.md) |
| ModelHub | [ANALYSIS](../Model/ModelHub/ANALYSIS.md) |
| ModelArtifactStore | [ANALYSIS](../Model/ModelArtifactStore/ANALYSIS.md) |
| Apple 모델 adapter 경계 | [ANALYSIS](../Model/FoundationModelsBridge/ANALYSIS.md) |
| MLX·LiteRT·LEAP native provider | [ANALYSIS](../Providers/ANALYSIS.md) |
| ChatGPT Account·Text·Image | [ANALYSIS](../Providers/ChatGPT/ANALYSIS.md) |
| NativeAgent 실행 시스템 | [ANALYSIS](../Agent/NativeAgentPackage/ANALYSIS.md) |
| ChatGPT Agent 조립·이미지 capability | [ANALYSIS](../Agent/NativeAgentPackage/Packages/ChatGPTImageCapability/ANALYSIS.md) |
| NativeAgentMCP | [ANALYSIS](../Agent/NativeAgentPackage/Packages/NativeAgentMCP/ANALYSIS.md) |
| ASK 지식 실행 시스템 | [ANALYSIS](../Knowledge/ASK/ANALYSIS.md) |
| ASKAgentTools | [ANALYSIS](../Knowledge/ASK/Packages/ASKAgentTools/ANALYSIS.md) |
| ASKTutor | [ANALYSIS](../Knowledge/ASK/Packages/ASKTutor/ANALYSIS.md) |
| UI 프레젠테이션 | [ANALYSIS](../UI/ANALYSIS.md) |
| Qualification·검증 도구·외부 경계 | [ANALYSIS](../Qualification/ANALYSIS.md) |

각 ANALYSIS가 caller/handler/input/state/effect/output·실제 경로·findings를 소유한다. 독립 제품 정체성은 [NativeAgent](../Agent/NativeAgentPackage/docs/IDENTITY_AND_EVOLUTION.md), [ASK](../Knowledge/ASK/docs/IDENTITY_AND_EVOLUTION.md), [ASKTutor](../Knowledge/ASK/Packages/ASKTutor/docs/IDENTITY_AND_EVOLUTION.md)가 소유한다. root는 이를 단일 제품으로 합치지 않는다.


## 현재 실행 경로와 변경

Account epoch/admission → ChatGPTSignInSession → callback serial queue → pure request parser/resource ledger → Network I/O → identity별 receipt → callback 결과 + native drain → Account state/code/token 검증 → credential commit 또는 retained failure.

listener만 취소하고 accepted connection을 놓던 경로를 제거했다. 미완료 I/O token과 cancelled receipt가 모두 필요하다. callback caller/start caller identity, bounded fail-closed drain, complete-invalid framing, retry 정수 경계를 보강했다. public API와 Keychain/OAuth wire identity, provider 선택·Agent/ASK domain은 바꾸지 않았다.


### 이번 추가 변경 — ModelHub identity

`HubModelAddress`와 `HubModelImportCandidate`가 각각 소유하던 Hugging Face repository/commit validation을 `HubRepositorySyntax`로 통합했다. 공식 repository ID 제한과 Git ref 안전 조건을 같은 경계에서 적용한다. Candidate ID는 provider와 length-prefixed artifact paths를 포함하므로 서로 다른 material candidate가 동일 ID가 되는 조합을 제거했다. backend protocol, install flow, cancellation semantics는 변경하지 않았다.

## 현재 검증 범위

| 단위 | 이번 결과 | 한계 |
|---|---|---|
| Core / Runtime / façade | 57 / 99 / 3 테스트 | controlled provider 계약; native 추론 아님 |
| Hub / AppleSystem common | 13 / 10 테스트 | Hub는 strict repo/ref identity 포함; 실제 다운로드/Apple 모델 분기 제외 |
| Account / Text / Image | 50 / 3 / 3 테스트, debug/release, 각 3회 반복 | Account native socket 14개는 Linux에서 NOT_RUN |
| TextProvider / NativeAgent target | 실제 manifest build PASS | TextProvider release도 PASS; full Manager 아님 |
| Agent exact-source kernel | 571 Swift Testing + 3 XCTest | Manager/NaturalLanguage 제외한 검증 manifest |
| ChatGPT wire | 44 테스트 × 3회, 실제 local HTTP | 원격 계정/서비스와 loopback 로그인 아님 |
| 공개 consumer | 재배치 6-package compile/link + Core/미지원 host 거부 실행 | README의 서비스 함수는 컴파일만 하고 호출하지 않음 |
| source / graph / syntax | 53 manifest graph, 482 static assertions, 1241 Swift files | native typecheck/link를 대체하지 않음 |
| Knowledge / optional ASK/MCP | 기존 source·계약 보존 | 이번 native library 재검증 범위 밖; 이전 PASS 승계 없음 |
| Apple / Keychain / 실제 계정·앱·모델 | NOT_RUN | 지원 SDK/device/credential/승인 부재 |

한 번씩 집계한 결과는 **Swift Testing 850 + XCTest 3 = 853개**, Python 23개는 별도다. 반복 실행과 외부 consumer 체크를 고유 테스트 수에 더하지 않는다. 전체 source archive의 추출본 검증과 hash는 [final report](verification/current/final-verification.json)를 따른다.

## UNKNOWN

Network.framework compile/runtime와 callback receipt ordering, native drain deadline, Keychain/iCloud 경쟁, 전체 ChatGPT/Agent/ASK/MCP 조립, artifact crash durability, native provider/model 수명, 실제 계정 지원/이미지 품질, iOS/macOS 앱 lifecycle는 미확인이다. callback의 MainActor 제거는 구현되어 있으며 남은 것은 native 검증이다. 이를 미구현으로 다시 적거나 테스트 성공으로 덮지 않는다.

## 2026-10-07 native baseline update

현재 의존성은 MLX Swift 0.32.3, MLX Swift LM 3.32.3, Hugging Face 0.13.0, Transformers 1.3.4, LiteRT-LM 0.18.0, LEAP 0.11.0-SNAPSHOT이다. LEAP upstream은 프리릴리스다. Root는 MLXProvider/MLXModelRegistry를 공개하며 LEAP 형제 inference_engine을 함께 연결한다. 이전 AppleLocalAI/MigrationHold·옛 release 도구·nested LEAP 서명 도구는 명시적 폐기 요청으로 제거했다. 기존 게시 버전은 다시 쓰지 않는다. 실제 실행 상태는 새 검증 보고서에서 확인하며 unrelated SDK gate를 PASS로 승계하지 않는다.

최신 dependency update의 범위와 실제 검증은 [0.1.2 보고서](verification/current/native-libraries-20261007/REPORT.md)가 소유한다. Swift Markdown 0.9.0 및 SwiftMCP 0.4.2도 갱신·검증했다. 실기기 실행 미확인은 보고서에 별도로 표시한다.
