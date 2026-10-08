# 외부 근거·버전 기준

> 이 문서는 입력 baseline의 기록이다. 현재 구현/숫자/출시 판정은 [Production review](production/IMPLEMENTATION_REVIEW.md)와 [Qualification](production/QUALIFICATION.md)을 따른다.

## 이번 확인

확인일 2026-09-20. 로컬 compiler는 Swift 6.2.1, Linux x86_64다. 외부 자료는 언어 의미의 근거이며 이 저장소의 build/runtime 성공 증거가 아니다.

| 출처·버전 | 확인한 의미 | 적용·한계 |
|---|---|---|
| [Swift 공식 언어 문서 — Concurrency](https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide/Concurrency.md), main 조회본 | cancellation은 협력적이며 Task.checkCancellation/isCancelled로 관찰한다. unstructured task의 수명 책임은 생성자에게 있다 | registry/Hub 취소 경계와 producer completion 구분. native SDK가 종료됐다는 증거는 별도 |

현재 웹 문서의 main은 변경 가능한 참조다. 실제 수정의 근거는 [수정 전 재현·현재 tests](verification/README.md)이며, 외부 Swift 문서는 그 해석을 보조한다.

## 입력에서 보존한 참고

[동결된 조사 입력](design-input/docs/research/2026-09-20-foundation-models-compat.md)의 Apple LanguageModel, foundation-models-utilities와 고정 MLXFoundationModels revision은 기존 설계 배경이다. 이번 검토에서 최신 Apple API signature·SDK27 설치·native inference를 검증했다고 승계하지 않는다.

실제 availability/conditional import/정확한 API 사용은 각 manifest/source가 정의한다. 실행 시점 OS 조건과 compiler가 선언을 볼 수 있는 SDK 조건은 다르다. 이 환경에서 제외되는 native 본문은 NOT_RUN이다.

## Dependency 판단

외부 pin/lockfile은 변경하지 않았다. MLX·LEAP·LiteRT의 선언/의존 방향은 source 검사 범위이며 remote resolve·binary link·실기기 동작은 별도다. ASKAgentTools의 이번 실행 실패는 Git cache/repository 경로 진단으로 기록했다. 과거 DNS 실패를 현재 원인으로 확정하거나 dependency/stub으로 우회하지 않았다.

source revision, Swift tools version, binary version, OS deployment target, model artifact digest는 서로 다른 식별자다.

## 2026-09-20 — ChatGPT owned completion 후속

실제 local URLSession 실패 로그와 Swift 6.2.1 FoundationNetworking의 redirect callback 구현을 대조했다. callback 전에 session cancellation을 진행하면 내부 redirect 대기 상태와 충돌할 수 있으므로 거절 callback을 완료한 뒤 task 종료 경계에서 정리한다.

Apple의 `didBecomeInvalidWithError` 계약은 `finishTasksAndInvalidate`가 마지막 task 종료를 기다리는 반면 `invalidateAndCancel`은 invalidation callback을 즉시 전달할 수 있다고 설명한다. 이에 task completion과 session invalidation 둘 다를 completion receipt로 요구했다. 실제 코드/시험이 현재 동작의 근거이며 아래 문서는 설계 계약의 근거다.

- [Apple: session invalidation callback](https://developer.apple.com/documentation/foundation/urlsessiondelegate/urlsession(_:didbecomeinvalidwitherror:))
- [Apple: invalidateAndCancel](https://developer.apple.com/documentation/foundation/urlsession/invalidateandcancel())
- [Swift 6.2.1 FoundationNetworking redirect implementation](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2.1-RELEASE/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift)

Codex protocol 참조는 공식 최신 [rust-v0.161.0](https://github.com/openai/codex/releases/tag/rust-v0.161.0)의 `979011409de0a60b52f179721948e65531d26144`로 갱신했다. 공식 login/auth/default client의 issuer·client ID·originator·callback port와 모델 backend 주소를 대조했다. commit의 존재가 실계정 text/image endpoint 호환성을 증명하지는 않는다.
