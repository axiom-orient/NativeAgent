# ChatGPTAgent

`ChatGPTAgentFactory.make`를 제공하는 선택형 host composition adapter다.
`ChatGPTTextProvider`에서 Agent 의존성을 제거하기 위해 기존 factory를 이 package로 옮겼다.
호출자는 `import ChatGPTAgent`를 사용한다. 기존 factory parameter와 AgentManager 동작은 유지한다.

계정 상태 admission → provider registry → AgentManager → createAgent → handle 순서를 유지한다.
인증 불가 상태에서 Agent를 먼저 생성하지 않는다. 추가 capability와 SkillIntentService는 그대로 전달한다.
Image capability는 host가 별도로 선택하며 자동 추가하지 않는다.

Agent state/lifecycle을 새로 보관하지 않는다. Linux에서는 Security/NaturalLanguage 전체 graph를 검증하지 못했다.
[workspace verification](../../../../docs/verification/README.md)을 따른다.
