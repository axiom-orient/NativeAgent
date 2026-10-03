# ChatGPTImageCapability

독립 [ChatGPTImage](../../../../Providers/ChatGPT/Image/README.md)를 NativeAgent의 승인·effect·artifact·복구 경계에 연결합니다. `images.generate/edit`, catalog list/read/run, layers plan/render, 선택 effect skills를 제공합니다. Text provider에는 의존하지 않습니다.

## 명시적 조립

```swift
import NativeAgent
import ChatGPTAccount
import ChatGPTImage
import ChatGPTTextProvider
import ChatGPTAgent
import ChatGPTImageCapability

let imageClient = try ChatGPTImageClient(account: account)
let imageCapability = ChatGPTImagesCapability(client: imageClient)
let imageIntents = ChatGPTImageSkills.makeIntentRouter(client: imageClient)
let agent = try await ChatGPTAgentFactory.make(
  account: account,
  dataStore: .directory(appDataURL),
  id: "main", name: "Main", soul: "정확하게 작업한다.",
  additionalCapabilities: [imageCapability],
  skillIntentService: imageIntents
)
// default recipes가 필요할 때만, host가 소유한 해당 Agent의 SkillLibrary에 설치합니다.
// try await ChatGPTImageSkills.installDefaultSkills(into: skillLibrary)
```

이 예시는 Text+Image host입니다. 같은 capability는 로컬 Text provider를 사용하는 일반 AgentManager/kernel에도 주입할 수 있습니다. image raw 호출만 필요한 앱은 이 package 대신 ChatGPTImage만 사용합니다. 기존 host intent router가 있다면 `registerDefaultHandlers(on:client:)`로 필요한 handlers를 결합하고 기존 router를 덮어쓰지 않습니다.

도구 등록, intent handler 등록, default recipe 설치는 서로 다릅니다. `installDefaultSkills(selected: false)`는 설치된 recipe의 선택 상태를 바꾸는 것이지 이미지 도구를 끄는 플래그가 아닙니다. authority는 항상 기존 kernel에 있습니다.

## 결과와 실패

provider의 성공만으로 작업 완료를 선언하지 않습니다. 구조/alpha 검사, semantic review, artifact commit을 구분합니다. `structural_only`/`needs_repair`는 요청의 모든 조건을 만족했다는 뜻이 아닙니다. preflight·명시 4xx 거부와, 5xx/transport/응답 해석 실패의 `outcomeUnknown`을 구분합니다. 후자는 같은 paid effect의 안전한 자동 retry 증거가 아닙니다.

카탈로그는 31개 prompt와 19개 category의 source→generator→bundled resource 관계를 유지합니다. WebP 예시는 새 생성 결과가 아닙니다. 레이어 plan은 source digest/canvas/back-to-front order를 결속하고 render는 호출당 한 후보만 만듭니다. alpha PNG가 재조합 원본이고 chroma PNG는 projection입니다. 자동 segmentation이나 가려진 원본의 정확한 복원은 보장하지 않습니다.

[IMAGE_PROMPTS](IMAGE_PROMPTS.md) · [IMAGE_LAYERS](IMAGE_LAYERS.md) · [Agent Current](../../docs/IMPLEMENTATION_STATUS.md) · [통합 검사](../../../../Qualification/ChatGPTCompositionChecks/README.md). attribution과 runtime PromptSources/Resources를 보존합니다.
