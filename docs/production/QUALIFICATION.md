# Qualification — 이번 실행과 남은 gate

**Source refactor 검증: local PASS. Production release: BLOCKED.** Linux x86_64 / Swift 6.2.1. 정확한 command/exit/source hash는 [verification index](../verification/README.md)와 [final JSON](../verification/current/final-verification.json)을 따른다. 입력의 과거 PASS는 합산하지 않는다.

## 이번 통과 범위

실제 manifest의 Core 57, Runtime 99, façade 3, Hub 10, AppleSystem common 10, Account 50, Text 3, Image 3과 NativeAgent target/TextProvider build를 확인했다. Agent exact-source kernel은 571 Swift Testing + 3 XCTest이며 Manager를 제외한 임시 검증 manifest를 사용한다. wire 44개는 실제 local URLSession/HTTP fixture를 포함한다. **고유 850 Swift Testing + 3 XCTest = 853개**, Python source-closure 9 + release-boundary 14는 별도다.

Account/Text/Image의 release tests와 TextProvider release build도 통과했다. Account/Text/Image는 각각 3회 반복했고 wire는 총 3회 통과했다. 반복은 고유 합계에 더하지 않는다. 6-package closure의 원본 SHA를 확인한 뒤 공개 README body를 consumer에서 컴파일·링크했다. Core projection/UTF-8 snapshot과 Linux의 명시적 unsupported account 동작만 실행했다.

53 manifest의 정적 dependency graph, 482 assertions, 1241 Swift 파일의 parse를 실행했다. 이를 전체 manifest `dump-package`나 Apple typecheck로 표시하지 않는다. unchanged Knowledge/ASK/MCP는 재검증하지 않았으며 source 보존만 확인한다.

## 현재 gate

| Gate | 판정 | 필요한 증거 |
|---|---|---|
| G0 Contract | PASS_LOCAL | 공개 API 선언·pin 보존, 로컬 회귀, 외부 consumer compile/link |
| G1 Unit | PASS_LOCAL | 위 실행 범위만; native 14개는 제외 |
| G2 Integration | PARTIAL | 실제 local HTTP; native callback/Keychain/full composition 남음 |
| G3 Native | NOT_RUN / BLOCKED | Apple SDK compile/link, Network callback ordering·deadline, native model settle/unload |
| G4 Cloud | NOT_RUN / BLOCKED | 지원/사용 권한 확인, 승인된 실제 계정·이미지·quota·cancel |
| G5 Host | PARTIAL / BLOCKED | public consumer의 pure 실행만; 앱 scene/background/logout/relaunch 미검증 |
| G6 Security·Durability | PARTIAL / BLOCKED | parser/epoch는 로컬 검증; Keychain sync/process 경쟁·artifact crash·privacy 남음 |
| G7 Source archive | final JSON 참조 | 보존·SHA/ZIP·추출본 source 검증; signed binary나 store release 아님 |

## 환경 확인과 실패 의미

`swiftc -typecheck`로 Network/CryptoKit/NaturalLanguage import를 각각 시도했고 모듈 부재로 실패했다. xcodebuild/xcrun도 없다. [environment-gates](../verification/current/environment-gates.json)에 정확한 diagnostic을 보존했다. 같은 사유로 full SDK build를 반복하지 않았다. native branch가 Linux에서 제외되어 생긴 0-test 실행을 통과라고 세지 않는다.

Account의 `CallbackNativeTests` 14개는 구현했지만 실행하지 않았다. shutdown deadline이 실제 부하에서 적절한지, Swift 6 SDK annotation과 queue ordering이 일치하는지도 NOT_RUN이다. pure ledger의 receipt 순열 테스트는 native가 그 receipt를 제공한다는 증거가 아니다.

## 지원 Apple 환경의 첫 실행

```sh
BUILD_ROOT="$(mktemp -d)"
swift --version
xcodebuild -version
swift test --package-path Providers/ChatGPT/Account --scratch-path "$BUILD_ROOT/account" -Xswiftc -warnings-as-errors
swift test --package-path Providers/ChatGPT/Account --scratch-path "$BUILD_ROOT/account" --filter CallbackNativeTests -Xswiftc -warnings-as-errors
swift test --package-path Qualification/ChatGPTCompositionChecks --scratch-path "$BUILD_ROOT/composition" -Xswiftc -warnings-as-errors
```

실제 callback 성공·timeout·취소·이미 끝난 callback·동시 connection·over-admission·포트 점유 뒤 accepted count 0, cancellation receipt, immediate rebind를 확인한다. Account state/code/PKCE/token 검증·signOut/refresh/relogin을 Keychain과 연결한다. drain 실패 뒤 새 client/로그인으로 우회하지 않는다.

## 나머지 검증 경계

각 provider의 실제 artifact digest와 OS/device를 고정해 load→generate→warm reuse→cancel→settle→reuse→unload→reload를 기록한다. borrowed close는 resident unload가 아니다. low memory/storage, corrupted tokenizer, late callback, shared load의 waiter 취소를 구분한다.

Keychain synchronizable/AfterFirstUnlock은 이번에 변경하지 않았다. 단일 Account actor는 다중 process/iCloud rotation lock이 아니다. device-only migration은 정책·데이터 보존·철회 계약부터 확정한다. Agent/Artifact의 process-kill·unknown outcome reconcile·atomic publication·lease/delete는 실제 filesystem/host에서 확인한다.

ASKAgentTools/MCP 외부 dependency와 peer 검증은 남아 있다. 이전 imported-baseline의 resolution 실패를 이번 실행 실패로도, 이번 PASS로도 재분류하지 않는다. 실제 계정 suite의 `NATIVEAGENT_LIVE_AUTH_FILE` / `NATIVEAGENT_LIVE_IMAGES`는 승인된 opt-in만 사용한다. raw credential은 기록·패키징하지 않는다.
