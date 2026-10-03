# Callback completion research — 2026-09-20

이번 조사 범위는 Network callback 수명, Swift cancellation/ordering, HTTP request framing이다. 외부 설명은 설계 근거이며 실제 Apple SDK 실행 증거가 아니다. 이전 제품·서비스 리서치는 하단에 별도로 보존한다.

| 직접 확인한 1차 출처 | 코드에 적용한 결정 | 증거의 한계 |
|---|---|---|
| [Apple WWDC18 715 transcript](https://developer.apple.com/videos/play/wwdc2018/715/) — start queue, connection cancelled terminal, listener/newConnectionHandler | listener와 accepted connection을 별도 소유하고 한 serial queue에서 callback을 직접 처리 | 현재 SDK의 실제 순서·typecheck를 수행한 것이 아님 |
| [Swift SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) — cancellation은 cooperative, executor scheduling | 취소 signal과 join 분리; callback별 MainActor Task hop 제거; caller identity로 unrelated cancellation 차단 | 상태기계 테스트는 native callback 제공을 증명하지 않음 |
| [RFC 9112 §§2.2, 3.2, 5, 6.3](https://www.rfc-editor.org/rfc/rfc9112.html) — byte framing, Host, header/body 경계 | byte delimiter, complete-invalid 즉시 거절, 중복 Host/control/TE/nonzero Content-Length 거절 | narrow callback profile이며 범용 HTTP 구현을 주장하지 않음 |
| [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html) — native OAuth / loopback / PKCE | 기존 등록 redirect/PKCE/state와 외부 browser 역할 보존 | 공개 client ID가 임의 앱의 서비스 사용 승인은 아님; 기존 port/profile 무단 변경 안 함 |

16 KiB는 기존 request 정책을 유지했다. 8개 admission과 5초 drain 상한은 이번 내부 안전 정책이며 위 표준이 정한 값이 아니다. 상한은 과부하/미증명 종료를 명시적 실패로 바꾸며 native 완료를 합성하지 않는다. 실제 device 부하에 따른 조정은 native qualification 결과와 함께 한다.

원본의 `attempt + 1`은 Int.max에서 실제 trap을 일으켰다. 이는 최신 라이브러리 문제가 아니라 로컬 산술식의 결함이므로 음수 guard와 덧셈 없는 범위 판정으로 해결했다. callback parser의 CRLF는 Unicode Character 개수가 아닌 byte 경계로 잘라야 한다. 작업 중 회귀를 테스트로 검출하고 고쳤으며 실패 로그도 보존했다.

## 입력에서 보존한 이전 리서치 · 이번 재검증 아님


아래는 입력 패키지에서 보존한 이전 리서치 기록이다. 이번 작업에서 모든 과거 웹 주장·SDK·pin을 재조회했다는 뜻이 아니다. 외부 문서는 설계 근거이지 이 저장소의 실행 성공 증거가 아니다. 원문은 [design input](../../design-input/production-readiness-20260920/README.md)에 그대로 보존했다.

## 결정과 교정

| 논점 | 확인·판단 | 적용 |
|---|---|---|
| 단일 public API | package별 명확한 진입점이라는 뜻이다. Model/Agent/ASK/Image를 한 인터페이스로 합치는 뜻이 아니다. | 기존 product/target/main API 보존. Account/Text/Image에는 각각 test target만 추가. |
| actor 안전성 | actor도 await 전후 상태를 자동으로 보존하지 않는다. Swift SE-0306의 reentrancy 설명과 일치한다. | credential/authorization generation을 await 뒤 재확인, cleanup admission을 먼저 예약. |
| cancel과 completion | Swift SE-0304에서 취소는 협력적 신호다. 신호와 producer/native 종료는 다른 사실이다. | 읽기 결과와 종료 결과 분리. 취소된 cleanup 대기자도 owner의 동일 결과를 join. |
| 실패한 종료 | 실패 상태 이름만 보존하고 invocation을 버리는 것은 소유권 증명이 아니다. | Runtime·Account·Image의 실제 operation 참조를 quarantine에 보존. weak lifetime 회귀로 확인. |
| OAuth refresh | RFC 9700의 회전 토큰은 이전 토큰 재사용에 위험이 있다. RFC 6749의 invalid_grant는 영구 거부 범주다. | refresh 단일 owner, 오래된 commit 차단, 저장 실패 시 자동 재시도 금지, 429/5xx는 영구 삭제로 분류하지 않음. |
| native OAuth | RFC 8252의 외부 브라우저/PKCE/loopback 지침을 참고한다. 공개 Codex client ID 사용이 임의 앱의 지원 계약이라는 뜻은 아니다. | 기존 PKCE/S256·등록 redirect·state 검증 보존. UI/browser는 host. |
| Apple 모델 façade | WWDC26 339는 model/configuration/executor와 session별 executor store를 설명한다. | 현재 one-way bridge와 config identity 유지. 실제 native resident 소유권은 별도 LocalBackend에 유지. Apple API를 본뜬 이름으로 완전한 parity를 주장하지 않음. |
| Apple 플랫폼 범위 | WWDC26 241/339에서 custom models·PCC·CoreAI·MLX를 확인했다. | 새 dependency/기능을 이번 범위에 끼워 넣지 않음. 지원 SDK의 실제 signature/link/run은 G3. |
| Apple utilities | 원본의 ‘실험적 utilities’ 단정은 근거가 부족하다. 현재 upstream README에는 1.0.0 dependency 예시가 있다. 이것만으로 안정성 인증도 할 수 없다. | 필요 없는 dependency는 추가하지 않음. context/skills는 선택 참고 패턴. |
| ChatGPT subscription | 공식 auth 문서는 Codex의 subscription/API key 로그인 방식을 설명한다. 범용 제3자 iOS 이미지 API를 승인하는 문서는 아니다. | 현행 provider pin/API/폴더명 유지, 배포 상태는 Experimental. API key backend로 몰래 전환하지 않음. |
| App Server | 공식 문서의 remote Code Mode host 절은 app-server command/WebSocket의 실험적·production 미지원 성격을 경고한다. version별 schema 생성은 지원한다. | ‘App Server로 교체하면 상용 지원 문제가 해결된다’고 결론내리지 않음. 별도 macOS 요구·권한·버전 qualification이 필요. |
| Responses background | 공식 API의 background+stream은 sequence_number/starting_after 재연결 계약을 갖는다. | 현재 subscription stream에 이 계약이 있다고 가정하지 않음. reconnect/재실행 기능 미추가. |
| Image background | 공식 Images 안내에서 gpt-image-2는 현재 transparent 배경을 지원하지 않는다고 명시한다. 공개 API와 subscription endpoint는 동일 계약으로 추론할 수 없다. | 기존 background=auto pin 유지. 기존 .transparent는 prompt 의도일 뿐 alpha 보장이 아님. 실제 raster/alpha 확인 없이 transparent 성공 표시 금지. |
| API key 보안 | 공식 지침은 서비스 키의 browser/mobile 배포를 피하도록 한다. | 새로운 API-key provider/키 저장 fallback/프록시/Go gateway 없음. |
| dependency pin | MLX-LM pinned manifest의 기본 FoundationModelsIntegration trait와 SwiftSyntax 범위를 확인했다. LiteRT release metadata와 LEAP manifest checksum 선언을 대조했다. | 기존 pin/trait/binary checksum 그대로. 다운로드·링크·실기기 검증으로 과장하지 않음. |
| 문서 수 | 원본 Execution Plan은 ‘7개’라고 쓰지만 예시에는 8개가 있다. 고정 숫자에 맞춘 파일 삭제는 근거가 아니다. | 현재 canonical 문서 경로 유지, 최신 상태/검토/원본 evidence를 구분. |
| cleanup | MigrationHold가 활성 graph 밖이라는 사실은 public parity가 끝났다는 뜻이 아니다. | 보존 영역/선택 adapter 삭제 안 함. 캐시·작업용 Git은 배포 archive에서 제외. |

## 원본 19개 출처의 대조

| 원본 번호 | 내용 | 확인 방법·한계 |
|---|---|---|
| 1–2 | Foundation Models overview/updates | Apple 공식 WWDC26 241/339 transcript로 기능·아키텍처 대조. SDK 실행은 미확인. |
| 3 | Core AI model/session | 공식 339의 모델 선택 설명으로 원리 확인. 실제 CoreAI binary 배포/실행 미확인. |
| 4–5 | Guided generation/tools | 공식 241/339에서 framework 기능 확인. 현재 text-only adapter가 모두 지원한다고 확대하지 않음. |
| 6 | Foundation Models Utilities | 공식 GitHub README 직접 읽음. 원본 experimental 단정 교정. |
| 7 | PCC | 공식 241/339로 Apple-managed cloud 경계 확인. 이번 on-device provider PASS와 별도. |
| 8 | Codex authentication | 현재 공식 auth 문서 직접 확인. 경로 redirect 후 문서 기준. |
| 9 | App Server | 현재 공식 문서의 protocol/schema/experimental 경고 직접 확인. |
| 10 | Codex SDK | programmatic Codex라는 참고 방향만 사용. Swift/iOS embedded production 지원 근거로 사용하지 않음. |
| 11 | Responses streaming | 공식 streaming 안내와 현재 subscription SSE decoder를 별도로 취급. |
| 12 | Background | 공식 cursor/reconnect 설명 직접 확인. 현재 구현 capability로 승격하지 않음. |
| 13 | Image | 공식 현재 model/background 제한 직접 확인. snapshot endpoint와 구분. |
| 14 | API key safety | 공식 Help Center 지침 직접 확인. |
| 15 | PackageDescription | 공식 SwiftPM product/target/dependency 계약 + 실제 dump-package 결과 대조. |
| 16 | structured concurrency | Swift 공식 SE-0304의 취소·자식 수명으로 보강. |
| 17–18 | Swift Testing/traits | 실제 Swift 6.2.1 parameterized/timeLimit 테스트 실행으로 사용 API 확인. native 조건이 제외된 테스트를 PASS로 승계하지 않음. |
| 19 | MLX Swift | 실제 pinned MLX-LM manifest로 graph/trait 경계 보강. lazy GPU 완료는 기기에서 검증해야 함. |

## 1차 출처

문서 링크는 조회 기준이며 tag/commit은 아래 명시한 경우만 고정이다. JavaScript-only API 페이지의 추정 signature를 실제 SDK typecheck라고 보고하지 않는다.

- [Swift SE-0304 structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md): blob `f29c49d197eb9179f5de7f9d962e301a0c6684f5`, cancellation 절 확인.
- [Swift SE-0306 actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md): blob `4a1d6d0ee04e76f42244edd8da95b46231f19f68`, actor reentrancy 절 확인.
- [SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html).
- [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749.html), [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html), [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html): token 오류·native OAuth·현행 보안 지침.
- [Apple WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/), [Apple WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/).
- [Apple Foundation Models Utilities](https://github.com/apple/foundation-models-utilities/blob/main/README.md): 읽은 README blob `949d8aa475882018de2d862858ce7133432b272b`.
- [Codex authentication](https://learn.chatgpt.com/docs/auth), [App Server](https://learn.chatgpt.com/docs/app-server).
- [Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses), [background](https://developers.openai.com/api/docs/guides/background), [image generation](https://developers.openai.com/api/docs/guides/image-generation), [API key safety](https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety).
- [MLX-LM pinned manifest](https://github.com/ml-explore/mlx-swift-lm/blob/c6446cf7bfb7cea76408013b614d4b2c530eaa03/Package.swift): tools 6.2; 기본 FoundationModelsIntegration trait; SwiftSyntax 602..<604. NativeAI의 traits 제한을 변경하지 않음.
- [LiteRT-LM v0.17.0 release](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.17.0): Apple 두 asset의 SHA-256 metadata가 로컬 manifest와 일치. `swift/Package.swift@v0.17.1` 조회는 404였으며 성공 근거로 사용하지 않음.
- [LEAP pinned manifest](https://github.com/Liquid4All/leap-sdk/blob/v0.10.13-SNAPSHOT/Package.swift): Swift 6.0, iOS17/macOS15, LeapSDK binary checksum 선언 일치. SNAPSHOT을 안정 release로 재분류하지 않음.

## 검증하지 않은 추론

[UNVERIFIED] Xcode/SDK 27 전체 signature, CoreAI/MLX 실제 tensor/native 작업 종료, LiteRT/LEAP binary bytes의 재다운로드·checksum 계산·link, Apple Keychain/iCloud 경쟁, 실제 서비스 사용 권한·지원 계약·quota, transparent raster 품질. 위 항목은 [qualification](QUALIFICATION.md)의 차단 조건이다.
