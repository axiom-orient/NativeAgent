# AGENTS.md — NativeAgentProviderAppleLocalAI

상위 [`../../AGENTS.md`](../../../../AGENTS.md)를 적용한다.

이 package는 **projection만** 소유한다.

- model lifetime owner를 만들지 않는다.
- Agent approval/effect journal을 실행하지 않는다.
- Apple session history를 NativeAgent durable history로 복제하지 않는다.
- unsupported option/content를 silently drop하지 않는다.
- shared runtime을 executor/session deinit에서 shutdown하지 않는다.
- provider fallback이나 model download를 추가하지 않는다.

새 capability를 추가할 때는 Native `ModelRequest/Event`와 Apple `LanguageModelExecutor` 사이의 lossless mapping 또는 명시 rejection을 먼저 정의하고 테스트한다.
