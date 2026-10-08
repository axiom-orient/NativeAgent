# ChatGPTAccount

기존 `ChatGPTAccountSession`의 sign-in/PKCE/localhost callback/Keychain/refresh/sign-out을 소유하는 독립 Apple library입니다. Text·Image·ModelCore에 의존하지 않습니다. endpoint/profile와 공통 bounded transport는 service 경계에서 공유하지만 모델 선택·이미지 의미·Agent 실행을 소유하지 않습니다.

## 기존 로그인 사용

```swift
import ChatGPTAccount

let account = try ChatGPTAccountSession(credentialNamespace: "com.example.app")
let authorization = try await account.beginSignIn()
// host가 authorization.authorizationURL을 외부/system browser로 엽니다.
// 기존 localhost callback listener가 redirect를 수신합니다.
let signedInAccount = try await account.completeSignIn(authorization)
let status = try await account.status()
// 명시 취소: try await account.cancelSignIn()
// 명시 로그아웃: try await account.signOut()
```

host가 같은 namespace/account scope에 하나의 actor를 생성하고 Text·Image에 전달해야 합니다. package가 프로세스 전역 registry나 여러 프로세스의 Keychain writer lock을 대신 만들지 않습니다. 기존 namespace를 임의 변경하면 다른 credential slot을 읽게 됩니다. 앱/browser 열기·UI·서명·OS 조건은 host 책임입니다.

로그인 public API와 credential serialization은 보존합니다. catalog/`resolvedModel`/`rateLimits`는 [ChatGPTTextSession](../Text/README.md)으로 이동했습니다. 인증과 서비스 API 이동을 구분한 [현재 계정·텍스트·이미지 경계](../../../docs/adr/0003-split-chatgpt-text-image.md)을 따릅니다.

## 서비스 경계

Text·Image는 `@_spi(Service)`의 opaque authorization lease를 사용합니다. lease는 account epoch와 HTTPS origin에 결속되며 refresh/id token을 service에 내보내지 않습니다. raw bearer 문자열 getter는 추가하지 않았습니다. 같은 epoch에서의 refresh와 계정 교체를 구분하고, transport 재시도가 다른 계정으로 요청을 전환하지 않게 검사합니다. 이 SPI는 일반 host API가 아닙니다.

실제 source는 [AccountSession](Sources/ChatGPTAccount/ChatGPTAccountSession.swift), [Credentials](Sources/ChatGPTAccount/ChatGPTCredentials.swift), [protocol](Sources/ChatGPTAccount/ChatGPTProtocol.swift)이 정본입니다. Swift 6.2 / iOS 17을 선언합니다. 조정 코드와 테스트는 Linux에서도 빌드됩니다. 실제 Keychain/PKCE/callback 구현에는 Apple frameworks가 필요하며, 미지원 환경의 공개 생성자는 `invalidConfiguration`으로 실패합니다. 대체 credential 저장소를 만들지 않습니다.

[Agent Current](../../../Agent/NativeAgentPackage/docs/IMPLEMENTATION_STATUS.md) · [검증](../../../docs/verification/README.md). source 보존 대조와 실제 로그인 성공은 별개이며 실계정은 NOT_RUN입니다.

## Transport 완료 계약

서비스는 `ChatGPTTransport.invocation`이 반환하는 events/cancel/waitForCompletion을 사용한다. production transport는 HTTP task 종료와 session 무효화를 모두 확인한 뒤 완료한다. 요청 실패는 events로, 로컬 완료 불명은 wait port로 전달한다.

기존 stream-only custom transport는 직접 stream 호출과 source conformance를 유지한다. Account/Text/Image에 주입하려면 invocation을 구현해야 한다. 기본 invocation은 기존 invalidConfiguration으로 I/O 전에 거절한다. 단순 EOF/no-op을 completion이라고 선언하면 안 된다.

하나의 invocation 완료는 account 전체 종료가 아니다. signOut은 credential invalidation이며 모든 병행 서비스 작업의 자동 drain을 보장하지 않는다. host는 각 작업의 완료를 소유해야 한다.

## 인증 수명과 실패

`signOut()`은 새 인증 admission을 막고 credential/authorization epoch를 무효화한 뒤 sign-in과 refresh를 취소·join하고 저장된 credential을 삭제한다. 동시 호출은 같은 cleanup 결과를 기다린다. cleanup caller 취소는 이 순서를 단축하지 않는다. 재로그인은 이전 refresh 종료 전에 새 token을 commit하지 않는다.

종료 증명이 실패하면 재사용을 막고 실패한 operation들을 각각 보존한다. 반복 cleanup으로 보존 기록이 늘지 않도록 failure identity로 합친다. credential 삭제 성공은 native 종료 증명이 아니다. 한 actor/namespace의 보장이며, 여러 actor·프로세스·iCloud 기기의 refresh 직렬화를 보장하지 않는다.

기존 `kSecAttrSynchronizable=true`, `AfterFirstUnlock` 저장 정책은 보존했다. 이 동기화 정책의 rotation/복원/삭제 안전성은 상용 security gate에서 확인해야 한다. device-only 전환을 검증 없이 적용하면 기존 credential migration 계약을 바꾼다.

[구현 리뷰](../../../docs/production/IMPLEMENTATION_REVIEW.md) · [출시 조건](../../../docs/production/QUALIFICATION.md)

## Callback 종료와 독립 검증

Callback I/O는 UI/MainActor와 분리된 전용 serial queue에서 처리한다. listener뿐 아니라 수락한 모든 connection과 미완료 receive/send callback까지 종료가 확인되어야 cancel/wait가 성공한다. 완료 불명은 실패 owner에 보존하며, timeout을 성공으로 바꾸거나 같은 Account의 새 로그인으로 우회하지 않는다. HTTP 200은 callback 수신 알림이지 로그인 성공 표시가 아니다.

순수 parser/ledger 회귀는 이 package의 실제 manifest로 실행한다. Apple의 실제 socket 회귀도 `Tests/ChatGPTAccountTests/LocalhostCallbackServerTests.swift`에 있으므로 Agent 전체 조립이 필요 없다.

```sh
swift test --package-path Providers/ChatGPT/Account -Xswiftc -warnings-as-errors
# 지원 Apple 환경에서만 실제 Network/Darwin suite를 실행한다.
swift test --package-path Providers/ChatGPT/Account --filter CallbackNativeTests -Xswiftc -warnings-as-errors
```

Linux에서 위 filter가 선택한 native 테스트가 0개이면 PASS 증거가 아니다. 실제 gate와 남은 Keychain/PKCE/SDK 검증은 root Qualification을 따른다.

사용자 정의 ChatGPTTransport는 stream과 invocation을 모두 구현해야 한다. stream-only transport를 위한 기본 invocation 구현은 제공하지 않는다.
