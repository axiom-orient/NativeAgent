# NativeAgent SwiftPM products

소비 앱은 필요한 product를 직접 선택한다. Dependency, supported platform, external pins와 target graph는 연결된 Package.swift가 정본이다.

## NativeAgent package

아래 products는 모두 [NativeAgent/Package.swift](../Package.swift)에 정의된다.

- Kernel: NativeAgent, NativeAgentDomain
- Managed host composition: NativeAgentManager
- Optional domains: NativeAgentMemory, NativeAgentGoals, NativeAgentEvolution, NativeAgentEvolutionSkills, NativeAgentConsensus
- Optional adapters/capabilities: NativeAgentSkills, NativeAgentSkillsWeb, NativeAgentBrowser, NativeAgentHTML, NativeAgentTools, NativeAgentWeb

일반적인 관리형 Agent는 `NativeAgentManager`로 조립한다. 이 product는 `NativeAgent`, `NativeAgentDomain`, `NativeAgentSkills`, `LanguageModelCore`, `LanguageModelRuntime`에 의존한다. Skills workspace 조립도 Manager의 책임이다. identity/workspace 관리를 직접 소유하는 host는 저수준 `NativeAgent` kernel을 사용한다. 두 API는 같은 durable execution 구현을 사용한다.

Optional product는 kernel 사용의 전제조건이 아니다. 각 선택 product의 전이 의존성까지 서로 독립이라는 의미는 아니며, 정확한 graph와 지원 범위는 manifest를 따른다.

## Supporting packages

| Package manifest | Product | Responsibility |
|---|---|---|
| [LanguageModelCore](../../../Model/LanguageModelCore/Package.swift) | LanguageModelCore | Provider-neutral model contracts, request/event/schema와 value limits |
| [LanguageModelRuntime](../../../Model/LanguageModelRuntime/Package.swift) | LanguageModelRuntime | Invocation reservation, streaming, cancellation, drain와 runtime lifecycle |
| [ModelArtifactStore](../../../Model/ModelArtifactStore/Package.swift) | ModelArtifactStore | Validated model/artifact files, leases와 filesystem publication |
| [ModelHub](../../../Model/ModelHub/Package.swift) | ModelHub | Hugging Face model URL inspection과 LEAP/MLX/LiteRT backend별 가져오기 라우팅·provider 선택 |
| [ChatGPTAccount](../../../Providers/ChatGPT/Account/Package.swift) | ChatGPTAccount | 기존 로그인·credential·refresh와 service authorization |
| [ChatGPTText](../../../Providers/ChatGPT/Text/Package.swift) | ChatGPTText | Text metadata·request·SSE·tool/structured response |
| [ChatGPTImage](../../../Providers/ChatGPT/Image/Package.swift) | ChatGPTImage | 독립 image generate/edit·image-owned payload |
| [ChatGPTTextProvider](../../../Providers/ChatGPT/TextProvider/Package.swift) | ChatGPTTextProvider | Text-only ModelRuntime adapter |
| [ChatGPTAgent](ChatGPTAgent/Package.swift) | ChatGPTAgent | Text provider와 AgentManager의 선택형 조립 |
| [ChatGPTImageCapability](ChatGPTImageCapability/Package.swift) | ChatGPTImageCapability | 명시 Image 도구·skills·catalog·layers |
| [AppleSystemModelProvider](../../../Providers/AppleSystemModel/Package.swift) | AppleSystemModelProvider | Apple Foundation Models runtime adapter |
| [LEAPProvider](../../../Providers/LEAP/Package.swift) | LEAPProvider | LEAP text provider, LFM2 GGUF Hub installer와 별도 voice/native lifecycle |
| [LiteRTProvider](../../../Providers/LiteRT/Package.swift) | LiteRTProvider | LiteRT-LM runtime과 `.litertlm` Hub installer |
| [MLXProvider](../../../Providers/MLX/Package.swift) | MLXProvider, MLXModelRegistry | MLX model runtime과 safetensors Hub installer |
| [NativeAgentMCP](NativeAgentMCP/Package.swift) | NativeAgentMCP | Remote MCP tool adapter; peer/transport/auth lifecycle은 host-owned |

Provider readiness, model preparation, account login, OS permissions과 app lifecycle은 consumer 책임이다. Provider별 선택·수명 조건은 [PROVIDERS](../docs/PROVIDERS.md), host 조립은 [AGENT_MANAGEMENT](../docs/AGENT_MANAGEMENT.md)를 따른다.

소비 앱의 의존성 구성, URL 입력·진행 UI, 여러 backend 후보 선택, 설치된 모델의 호출·복원은 [Hugging Face 주소로 앱에 모델 추가하기](../../../Model/ModelHub/README.md)를 따른다. `HubModelInstaller.installAndLoad(from:using:)`는 한 가지 backend만 호환될 때 설치와 runtime 준비를 이어 준다.

Nested Qualification packages와 Xcode projects는 test/qualification harnesses다. Production app composition이나 기본 dependency가 아니다.

`NativeAILeapSDK`는 두 LEAP frontend의 공통 바이너리 배포 선언이며 ModelRuntime이나 model lifecycle을 소유하지 않는다.
