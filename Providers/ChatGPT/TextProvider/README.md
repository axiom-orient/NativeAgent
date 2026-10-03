# ChatGPTTextProvider

독립 ChatGPT text ModelRuntime/ModelProviderConnector package다. Agent를 의존하거나 생성하지 않는다.
로그인과 credential은 형제 Account package, text transport는 Text package가 소유한다.

`ChatGPTRuntime.makeRuntime`와 `ChatGPTProviderConnector`는 기존 공개 역할을 유지하며,
실행은 Core descriptor → ClientLanguageModel executor projection → 동일 ModelRuntime으로 이어진다.

기존 `ChatGPTAgentFactory`는 [선택형 ChatGPTAgent](../../../Agent/NativeAgentPackage/Packages/ChatGPTAgent/README.md)로 이동했다.
factory 사용자는 `import ChatGPTAgent`를 추가한다. 텍스트 선택이 image capability를 켜지 않는다.

실계정/native 전체 검증 여부는 [workspace verification](../../../docs/verification/README.md)을 따른다.
