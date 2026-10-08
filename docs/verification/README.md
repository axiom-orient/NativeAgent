# Verification — NativeAgent SPM Candidate

## Current · 2026-10-08

[메인 통합 검증](current/main-consolidation-20261008/REPORT.md)이 현재 변경의 명령·입력 hash·실행 한계를 소유한다.
[현재 native 라이브러리](current/native-libraries-20261007/REPORT.md)와
[EmbeddingGemma 2](current/embedding-workflow-20261007/REPORT.md)의 고정 모델·실기기 결과를 별도로 확인한다.
원격 source ZIP은 정확한 Git revision의 self-excluding SOURCE_MANIFEST와 SHA-256을 검증해 수동 게시한다.

## Historical candidate · 2026-10-03

This is the current evidence for the local `NativeAgentSumday` package candidate. It does not verify the Sumday Xcode app integration, device behavior, live accounts/providers, or production qualification. The candidate has not been pushed or tagged. See [the exact checks](current/predeploy-candidate.json). **Production release remains BLOCKED.**

The 2026-09-20 callback-refactor results below are historical evidence for that earlier source tree. They are not proof for the SPM candidate.

## Historical callback refactor · 2026-09-20

Linux x86_64 / Swift 6.2.1. The earlier execution tree is retained below for its original logs; the current SPM-candidate evidence is `current/predeploy-candidate.json`.

[현재 SPM 후보 검사](current/predeploy-candidate.json) · [2026-09-20 machine report](current/final-verification.json) · [변경·보존](current/change-review.json) · [리뷰](../production/IMPLEMENTATION_REVIEW.md) · [출시 gate](../production/QUALIFICATION.md).

## 이전 실행의 실제 결과

| 대상 | 결과 | 근거·범위 |
|---|---|---|
| Core / Runtime / façade | 57 / 99 / 3 Swift Testing | [실제 portable manifest](current/portable.json) |
| Hub / AppleSystem common | 10 / 10 | 같은 portable; native/model/download 제외 |
| Account / Text / Image | 50 / 3 / 3 | 같은 portable; 실제 actor/pure parser/ledger, controlled I/O |
| NativeAgent target / TextProvider | build PASS | 실제 manifest; Manager 제외 |
| Agent selected kernel | 571 Swift Testing + 3 XCTest | [exact-source](current/native-kernel.json); 검증 manifest만 Manager 제외 |
| ChatGPT wire | 44 tests, real local HTTP | [wire](current/chatgpt-wire.json); remote service 아님 |
| Release | Account 50 / Text 3 / Image 3, TextProvider build | [optimized](current/release.json), warnings-as-errors |
| 반복 | Account/Text/Image 각각 3회; wire 총 3회 | [local repeat](current/repeat-runs.json), [wire repeat](current/chatgpt-wire-repeat.json) |
| 재배치 public consumer | compile/link/Core·unsupported-host 동작 PASS | [실행](current/consumer-qualification.json), [컴파일한 코드](current/consumer-inputs.json) |
| Python | closure 9 / release-boundary 14 | [closure log](current/supervisor-closure.log), [boundary log](current/supervisor-release-boundary.log) |
| Graph / syntax | 53 manifests, 482 assertions, 1241 Swift files | [static checks](current/static-checks.json); native typecheck 아님 |
| 문서·파일·추출본 | 최종 JSON의 결과 참조 | [문서](current/document-check.json), [archive](current/archive-recheck.json), [보존](current/change-review.json) |

**고유 Swift Testing 850 + XCTest 3 = 853개.** Python 23개는 별도다. 인자별 case, release/repeat/archive 재실행을 고유 개수에 더하지 않는다. 이전 1,063개 수치는 imported 기록이며 이번 합계가 아니다.

## Native / live 미검증

Account native socket 14개, Network.framework queue/typecheck/deadline, Keychain/PKCE/iCloud, 전체 Apple/Agent/ASK/MCP/Artifact, 실제 모델/계정/이미지/호스트는 NOT_RUN이다. [환경 import probe](current/environment-gates.json)에서 Network/CryptoKit/NaturalLanguage 부재를 실제 확인했다. 미지원 SDK를 stub으로 대체하지 않았다.

## 재현 및 기록 해석

```sh
python3 tools/verify-portable.py
python3 tools/verify-native-kernel.py
python3 tools/verify-chatgpt-wire.py
python3 tools/test-package-closure.py
python3 tools/test-distribution-manifest.py
python3 tools/check-boundaries.py
python3 tools/check-documents.py
```

`regressions/baseline-probes.json`은 원본 parser와 retry의 RED 재현이다. `account-round1-fixed.log`의 3개 실패는 새 parser의 CRLF 절단 결함이며 수정 후 최종 Account 50개가 통과했다. macro harness 오류와 중단된 verification observer는 별도로 표시했다. `round1-portable`의 49개 결과는 마지막 회귀 추가 전 스냅샷이다. 최종 50개 결과와 섞지 않는다.

[provenance](current/provenance.json)는 입력 ZIP과 입력 manifest hash를 보존한다. 현재 루트 `SOURCE_MANIFEST.json`은 2026-10-03 후보 트리의 자체 제외 파일 인벤토리다. 이전 트리 manifest는 `imported-baseline/SOURCE_MANIFEST-before-public-SwiftPM-20261003.json`에 보존한다. 공개용 기록의 로컬 홈·임시 경로는 `$NATIVEAGENT_ROOT`, `$SUMDAY_ROOT`, `$TMPDIR`, `$DATA_ROOT` 같은 자리표시자로 정규화한다. 이 값은 재실행 가능한 실제 경로가 아니며 production configuration이 아니다. 과거 package-root 전환 전 source-hash 보고서는 historical snapshot이며 현재 배포 후보의 검증으로 승계하지 않는다. 배포 검토는 `current/predeploy-candidate.json`의 범위와 한계를 따른다.
