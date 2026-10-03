# ADR-0001 — Host-owned shared local backend

- **Status:** Accepted
- **Date:** 2026-09-19

## Context

NativeAgent와 AppleLocalAI가 MLX/LEAP/LiteRT 같은 local model backend를 각각 독립적으로 load하면 같은 모델의 resident 수명, cancel, unload authority가 중복될 수 있다. Apple `LanguageModelSession` executor cache는 이 전역 lifetime 문제를 해결하지 않는다.

## Decision

1. Host가 backend configuration마다 하나의 `LocalBackend`를 만든다.
2. `LocalBackend`가 model load와 최종 resident release를 소유한다.
3. `LocalBackend`가 생성한 하나의 `ModelRuntime`이 invocation admission/cancel/drain을 소유한다.
4. NativeAgent와 Apple bridge는 동일 runtime을 borrowed access로 사용한다.
5. AgentManager의 operation cleanup은 `ModelRuntimeAccess`를 통해 owned와 borrowed를 구분한다.
6. Apple executor/session은 shared runtime을 load/unload하지 않는다.
7. runtime drain이 실패하면 resident release하지 않고 failed state를 유지한다.
8. routing, model download, cloud fallback, retry policy는 LocalBackend 책임이 아니다.

## Consequences

- 두 frontend가 같은 model resident와 invocation gate를 공유할 수 있다.
- host가 최종 shutdown 시점을 명시해야 한다.
- standalone AppleLocalAI loader와 shared LocalBackend loader를 같은 모델에 동시에 사용하면 자동 dedup되지 않는다.
- provider별 native completion을 실제로 증명하는 qualification이 필요하다.

## Rejected alternatives

- global singleton: app/test/account/configuration 경계를 숨긴다.
- reference-counted implicit unload: operation cleanup과 model lifetime owner를 다시 섞는다.
- HTTP/MCP gateway: 같은-process Swift composition에 불필요한 transport authority를 추가한다.
- Apple session이 model lifetime 소유: NativeAgent와의 공유 lifetime을 표현하지 못한다.
