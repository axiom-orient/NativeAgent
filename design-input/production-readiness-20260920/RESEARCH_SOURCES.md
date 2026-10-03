# NativeAI — Research Sources

기준일: 2026-09-20. 외부 자료는 아키텍처 판단의 근거이며 저장소 자체의 runtime PASS 증거가 아니다.

## Apple

1. Foundation Models overview  
   https://developer.apple.com/documentation/foundationmodels  
   - on-device / Private Cloud Compute / custom language model / guided generation / tools.

2. Foundation Models updates  
   https://developer.apple.com/documentation/updates/foundationmodels  
   - iOS 27에서 `LanguageModel` protocol, PCC, image analysis, tool calling mode, Instruments, CoreAI/MLX integration.  
   - OS update로 model이 바뀌므로 prompt 재검증 필요.

3. Running a Core AI model in a Foundation Models session  
   https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session  
   - custom on-device model을 동일 session API로 연결.

4. Guided generation  
   https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation  
   - Swift type 기반 constrained sampling.

5. Tool calling  
   https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling  
   - app database/network/framework effect와 tool integration.

6. Foundation Models Utilities  
   https://github.com/apple/foundation-models-utilities  
   - context management, skills, hosted-model client 등 emerging patterns. 실험적 utilities라는 성격을 유지해야 함.

7. Private Cloud Compute language model  
   https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute/  
   - larger context/reasoning, Apple-managed cloud model path.

## OpenAI

8. Codex authentication  
   https://developers.openai.com/docs/auth  
   - Codex는 ChatGPT subscription login과 API-key login을 공식 지원.

9. Codex App Server  
   https://developers.openai.com/docs/app-server  
   - product embedding용 JSON-RPC interface. auth, thread/turn, approvals, streamed events.  
   - generated schema를 pinned Codex version과 맞출 수 있음.  
   - WebSocket transport는 문서상 experimental.

10. Codex SDK  
    https://developers.openai.com/docs/codex-sdk  
    - programmatic Codex workflow. product lifecycle/approval/events를 직접 제어할 때 App Server 권장.

11. Responses API streaming  
    https://developers.openai.com/api/docs/guides/streaming-responses  
    - SSE streaming contract.

12. Background mode  
    https://developers.openai.com/api/docs/guides/background  
    - long-running response, polling, stream resume/sequence cursor.

13. Image generation  
    https://developers.openai.com/api/docs/guides/image-generation  
    - current image models, Images API and Responses image tool, output format/background configuration.

14. API key safety  
    https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety  
    - API key를 browser/mobile client에 배포하지 말고 backend에 보관.

## Swift

15. Swift Package Manager PackageDescription  
    https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html  
    - library product는 consumer에 공개되는 build artifact; target은 compile module boundary.

16. Swift structured concurrency / TaskGroup  
    https://docs.swift.org/latest/documentation/swift/taskgroup/  
    - structured child task lifetime과 cooperative cancellation.

17. Swift Testing  
    https://developer.apple.com/documentation/Testing  
    - concurrency integration, parameterized tests, runtime condition, tags.

18. Swift Testing traits  
    https://developer.apple.com/documentation/testing/traits  
    - environment/device/feature 조건과 test behavior를 명시적으로 분류 가능.

## MLX

19. MLX Swift  
    https://github.com/ml-explore/mlx-swift  
    - Apple silicon용 Swift MLX API, lazy evaluation, CPU/GPU execution.

## 현재 저장소에서 확인한 기준 파일

- `Model/LanguageModelCore/Package.swift`
- `Model/LanguageModelRuntime/Package.swift`
- `Model/NativeLanguageModels/Package.swift`
- `Providers/AppleSystemModel/Package.swift`
- `Providers/MLX/Package.swift`
- `Providers/LiteRT/Package.swift`
- `Providers/LEAP/Package.swift`
- `Providers/ChatGPT/{Account,Text,Image}/Package.swift`
- `Agent/NativeAgent/Package.swift`
- `Agent/NativeAgent/Packages/{ChatGPTAgent,ChatGPTImageCapability,NativeAgentMCP}/Package.swift`
- `Knowledge/ASK/Packages/ASKAgentTools/Package.swift`
- `docs/{ARCHITECTURE,SPEC,IMPLEMENTATION_STATUS,PLAN,RESEARCH}.md`

## 확인 상태 표기

- **[VERIFIED]** 공식 문서 또는 현재 저장소 source에서 직접 확인
- **[UNVERIFIED]** 실제 SDK/device/account 실행이 필요한 항목
- **[ASSUMPTION]** 제품 요구를 바탕으로 한 설계 선택; 구현 전에 caller 요구로 확정 필요

