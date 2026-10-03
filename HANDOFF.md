# NativeAI HANDOFF — Production Refactor · 2026-09-20

## 재개 기준

이번 리팩토링 기준선은 `NativeAI-Callback-Refactored-20260920.zip`이다. SHA-256은 `081d4cb372662db2fbd22533124192c1f31a26c04c30ed498150bd816b8b088f`다. 최초 계보 입력 `NativeAI-Production-Refactored-20260920(1).zip`은 이전 refactor 이력으로만 보존한다. 실제 source와 [Current](docs/IMPLEMENTATION_STATUS.md) → [구현 리뷰](docs/production/IMPLEMENTATION_REVIEW.md) → [검증](docs/verification/README.md) → [PLAN](docs/PLAN.md)을 읽는다. 작업 기억을 구현 증거로 사용하지 않는다.

## 이번 추가 리팩토링

`Model/ModelHub`에서 repository identity validation의 duplicate authority를 제거했다. `HubRepositorySyntax`가 Hugging Face repository ID, immutable commit, tree revision syntax의 단일 owner다. `HubModelAddress`와 `HubModelImportCandidate`는 이 owner를 공유한다. 유효한 public API shape는 유지하되, 공식 규칙 밖의 repo ID/ref는 더 이상 수락하지 않는다.

`HubModelImportCandidate.id`는 backend뿐 아니라 provider authority를 포함하고 artifact path를 길이-prefix로 직렬화한다. 따라서 `a,b + c`와 `a + b,c` 같은 서로 다른 file set 및 같은 backend 아래 다른 provider가 같은 candidate ID를 만들 수 없다. 기존 문자열 포맷을 intentional contract로 입증하는 caller/persistence evidence는 없었으므로 collision-safe identity를 정본으로 삼았다.

검증: ModelHub 13 tests × 3, release build, Core 57, Runtime 99, Account 50, Text 3, Image 3, NativeAgent target build 모두 Swift 6.2.1 `-warnings-as-errors` PASS. ModelArtifactStore는 Linux CryptoKit 부재로 NOT_RUN. Apple/native/live gate는 미확인이다.

## 구현한 것

`ChatGPTCallbackState`는 listener, 모든 accepted connection, 각 connection의 최대 한 개 미완료 I/O를 소유한다. UUID가 맞는 receipt만 반영하며 세 경계가 모두 닫혀야 drain이다. `ChatGPTLocalhostCallbackServer`는 MainActor 대신 전용 serial queue에서 native callback과 API admission을 직렬 처리한다. 같은 callback을 기다리는 두 번째 caller나 다른 start caller의 취소가 첫 owner를 취소하지 않게 identity를 확인한다.

명시 취소·성공·잘못된 요청·timeout·port conflict 모두 같은 shutdown 경로를 사용한다. 5초 drain 상한은 `shutdownTimedOut` 실패를 고정하며 늦은 receipt가 와도 그 실패를 성공으로 바꾸지 않는다. 기존 `ChatGPTSignInDrainFailure` → Account failure roots가 미증명 native owner를 보존한다. 자동 재생성·fallback·재로그인으로 우회하지 않는다.

HTTP parser는 incomplete/invalid/callback을 구분한다. body framing, 중복 Host, control 문자, pipelined bytes를 거절한다. CRLF 경계는 byte로 자른다. callback의 HTTP 200은 수신 알림일 뿐 OAuth 성공이 아니다. retry 정책은 음수와 Int.max에서 허용/overflow가 발생하지 않게 수정했다.

## 검증과 보존

현재 결과는 [final-verification.json](docs/verification/current/final-verification.json)의 exit/log/source hash를 따른다. 세 관점의 자기검토이며 독립 외부 리뷰어가 참여한 것은 아니다. 원본 결함의 red 로그, 작업 중 발견한 parser 회귀, 수정 뒤 결과를 구분했다. 이전 `current` 전체는 `docs/verification/imported-baseline/production-refactor-20260920`으로 이동했다. 과거 수치를 이번 실행에 합산하지 않는다.

public products/API, manifest/lockfile/provider pin, OAuth profile/port 순서, Keychain sync 정책, Agent/ASK 승인·원장, optional provider/image/MCP, MigrationHold는 보존했다. native socket 테스트를 Account leaf로 옮겨 전체 Agent 조립 없이 실행할 수 있다. 새 외부 dependency나 production stub은 없다.

## 첫 후속 실행 — 지원 Apple 환경

```sh
BUILD_ROOT="$(mktemp -d)"
swift --version
xcodebuild -version
swift test --package-path Providers/ChatGPT/Account --scratch-path "$BUILD_ROOT/account" -Xswiftc -warnings-as-errors
swift test --package-path Providers/ChatGPT/Account --scratch-path "$BUILD_ROOT/account" --filter CallbackNativeTests -Xswiftc -warnings-as-errors
swift test --package-path Qualification/ChatGPTCompositionChecks --scratch-path "$BUILD_ROOT/composition" -Xswiftc -warnings-as-errors
```

먼저 실제 Network.framework compile/link와 `CallbackNativeTests`를 검증한다. stalled connection, 정상 callback, 취소, timeout, admission 초과, port 충돌 후 resource count와 rebind를 관측한다. callback queue의 SDK 실행·deadline 분기와 Keychain/PKCE는 여기서 NOT_RUN이다. Linux source parse를 native typecheck라고 보고하지 않는다.

나머지 provider load→generate→cancel→settle→reuse→unload, Keychain 다중 process/device, artifact crash durability, 앱 lifecycle와 실제 서비스는 [Qualification](docs/production/QUALIFICATION.md)의 남은 gate다. 실계정 opt-in `NATIVEAGENT_LIVE_AUTH_FILE` / `NATIVEAGENT_LIVE_IMAGES`는 기존 계약을 지킨다. 계정·quota·이미지·tool effect 승인 없이 실행하지 않는다. credential을 로그/패키지에 넣지 않는다.

**소스 refactor 완료와 생산 배포 승인은 다르다. 현재 production release는 BLOCKED다.**
