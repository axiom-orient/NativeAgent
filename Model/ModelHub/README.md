# Hugging Face 주소로 앱에 모델 추가하기

이 안내서는 `ModelHub`를 연결하는 **소비 앱 개발자와 앱 사용자 경험**을 설명합니다. 이 저장소는 SDK 패키지 모음이라 모델 주소 입력 화면은 제공하지 않습니다. 앱은 입력란, 다운로드 진행 표시, 백엔드 선택 화면을 만들고 아래 SDK에 연결합니다.

완성된 사용 흐름은 간단합니다.

1. 사용자가 Hugging Face의 **모델 저장소 페이지 주소**를 붙여 넣습니다. 예: `https://huggingface.co/organization/model-name`
2. 앱이 설치된 엔진(LEAP, MLX, LiteRT)에 맞는 파일인지 자동으로 확인합니다.
3. 호환 엔진이 하나면 다운로드와 모델 준비를 시작합니다. 진행률을 표시합니다.
4. 같은 저장소가 여러 엔진과 호환되면 앱이 선택지를 보여 줍니다.
5. 준비가 끝나면 앱이 선택된 모델로 대화를 실행하고, 다음 실행을 위해 모델 선택을 저장합니다.

새 모델의 **파일 형식과 아키텍처가 앱에 포함된 엔진에서 이미 지원되면** 모델 파일을 다시 배포하지 않고 주소만으로 가져올 수 있습니다. 새 네이티브 아키텍처나 런타임 기능이 필요한 모델은 앱의 엔진 업데이트가 필요합니다.

## 1. 앱 빌드에 사용할 엔진 추가

앱의 Swift Package 의존성에 `ModelHub`, `ModelArtifactStore`, `LanguageModelCore`, `LanguageModelRuntime` 및 앱에 포함할 provider product를 추가합니다. 예제는 LEAP, MLX, LiteRT 세 엔진을 모두 포함합니다. 특정 앱에서 사용하지 않을 provider는 의존성·import·초기화 코드에서 함께 제거하세요. **앱 바이너리에 넣지 않은 엔진은 모델 주소만으로 추가할 수 없습니다.**

## 2. 앱 시작 때 provider와 installer를 한 번 구성

모델 파일과 카탈로그는 앱이 유지하는 영구 저장 공간에 둡니다. 임시 디렉터리를 사용하면 앱 재시작 뒤 모델을 다시 찾아오거나 내려받아야 할 수 있습니다.

```swift
import Foundation
import ModelArtifactStore
import LanguageModelCore
import ModelHub
import LanguageModelRuntime
import LEAPProvider
import LiteRTProvider
import MLXProvider

let appSupport = try FileManager.default.url(
  for: .applicationSupportDirectory,
  in: .userDomainMask,
  appropriateFor: nil,
  create: true
)
let modelsRoot = appSupport.appending(
  path: "NativeAgent/Models", directoryHint: .isDirectory)

let mlxRoot = modelsRoot.appending(path: "MLX", directoryHint: .isDirectory)
let mlxStore = try ModelArtifactStore(rootURL: mlxRoot)
let mlxRuntime = MLXTextRuntime(
  store: mlxStore,
  specificationsPersistenceURL: mlxRoot.appending(path: "catalog.json"))
let mlx = try MLXHubModelProviderConnector(runtime: mlxRuntime)

let leapRoot = modelsRoot.appending(path: "LEAP", directoryHint: .isDirectory)
let leapStore = try ModelArtifactStore(rootURL: leapRoot)
let leap = try LEAPHuggingFaceModelProviderConnector(
  runtime: LeapRuntime(store: leapStore),
  catalogPersistenceURL: leapRoot.appending(path: "catalog.json"))

let liteRTRoot = modelsRoot.appending(path: "LiteRT", directoryHint: .isDirectory)
let liteRTStore = try ModelArtifactStore(rootURL: liteRTRoot)
let liteRT = try LiteRTHuggingFaceModelProviderConnector(
  store: liteRTStore,
  catalogPersistenceURL: liteRTRoot.appending(path: "catalog.json"))

let connectors: [any ModelProviderConnector] = [mlx, leap, liteRT]
let providers = try ModelProviderRegistry(connectors)

let importBackends: [any HubModelImportBackend] = [mlx, leap, liteRT]
let installer = try HubModelInstaller(backends: importBackends)
```

LiteRT 모델 가져오기는 iOS/macOS 앱 빌드에 `CLiteRTLM` native backend가 연결된 경우에만 사용할 수 있습니다. 앱이 LiteRT를 포함하지 않거나 현재 빌드에서 native backend를 제공하지 않는다면 LiteRT 초기화와 목록 항목을 빼세요. 사용하지 않는 엔진을 등록하면 사용자에게 쓸 수 없는 선택지를 보여 주지 않도록 앱 설정과 일치시켜야 합니다.

## 3. 주소 입력 화면을 SDK 호출에 연결

사용자는 `.gguf` 같은 개별 파일 링크가 아니라 모델 저장소 페이지 주소를 붙여 넣습니다. SDK는 `namespace/repository`, `https://huggingface.co/namespace/repository`, 또는 특정 revision을 지정한 `/tree/<revision>`·`/commit/<40자리 SHA>` 주소를 받습니다. Hugging Face가 아닌 호스트, 직접 파일 주소, URL query/fragment는 받지 않습니다.

호환 형식이 하나인 일반적인 경우에는 한 번의 호출로 검사, 설치, provider 선택, runtime 준비를 할 수 있습니다.

```swift
// 다른 모델에서 바꾸는 경우에는 먼저 현재 대화를 끝내고 runtime을 종료합니다.
if let current = viewModel.activeAccess {
  try await current.release()
  viewModel.activeAccess = nil
}

let ready = try await installer.installAndLoad(
  from: pastedAddress,
  using: providers,
  progress: { progress in
    // 이 closure는 @Sendable입니다. SwiftUI 상태 갱신은 MainActor로 전달하세요.
    Task { @MainActor in
      viewModel.completedBytes = progress.completedBytes
      viewModel.totalBytes = progress.totalBytes
      viewModel.currentFile = progress.currentFile
    }
  })

// 앱 상태에 저장합니다. `ready.access.runtime`으로 바로 모델 요청을 보낼 수 있습니다.
viewModel.selectedModel = ready.model
viewModel.activeAccess = ready.access
```

화면에서는 `completedBytes / totalBytes`로 진행 막대를 그리고 `currentFile`로 현재 파일을 보여 줄 수 있습니다. 설치 중에는 주소 입력과 중복 설치 버튼을 잠그고, 실패하면 원인을 보여 주어 다시 시도할 수 있게 하세요. 모델 크기·저장 공간과 모델 라이선스 안내도 앱이 사용자에게 제공해야 합니다.

SwiftUI 화면에서는 아래처럼 입력란, 가져오기 버튼, 진행 표시를 연결할 수 있습니다. `viewModel`과 그 상태·`addModel()`은 앱이 구현합니다. SDK는 UI를 대신 만들지 않습니다.

```swift
TextField("Hugging Face 모델 주소", text: $viewModel.modelAddress)
  .textInputAutocapitalization(.never)
  .autocorrectionDisabled()

Button("모델 가져오기") {
  Task { await viewModel.addModel() }
}
.disabled(viewModel.isImporting || viewModel.modelAddress.isEmpty)

if let progress = viewModel.downloadProgress, progress.totalBytes > 0 {
  ProgressView(
    value: Double(progress.completedBytes),
    total: Double(progress.totalBytes))
  Text(progress.currentFile ?? "모델 다운로드 중")
}
```

한 저장소에서 둘 이상의 설치 backend가 호환 파일을 찾으면 `installAndLoad`는 임의로 하나를 선택하지 않고 `HubModelImportError.backendSelectionRequired`를 던집니다. 모델 크기와 엔진을 먼저 보여 주려면 선택 화면에서 다음 후보 조회 API를 쓰세요.

```swift
let choices = try await installer.candidates(for: pastedAddress)
// choices를 앱의 선택 화면에 표시합니다:
// displayName, 앱에서 읽기 쉬운 backend 이름, 사람이 읽기 쉬운 totalBytes
let chosen = choices[selectedRow]

let model = try await installer.install(chosen, progress: { progress in
  updateDownloadProgress(progress) // 앱의 UI 갱신 코드
})
let selection = try ModelProviderSelection(
  providerID: model.providerID,
  modelID: model.id)
let access = try await providers.acquireRuntime(selection)
let runtime = access.runtime
```

`choices`가 비어 있으면 현재 앱에 등록된 엔진 중 지원하는 형식을 찾지 못한 것입니다. 주소나 네트워크 검사 자체가 실패한 경우에는 별도 오류가 발생하므로, 이를 “지원하지 않는 모델”로 바꾸어 숨기지 말고 오류와 재시도 방법을 표시하세요.

## 4. 모델 실행, 저장, 다시 열기

간단한 텍스트 요청은 준비된 runtime에 `ModelRequest`를 전달합니다. 실제 앱에서는 기존 대화 기록을 `messages`로 넣고 반환된 `content`를 대화에 표시합니다.

```swift
let turn = try await ready.access.runtime.generate(
  ModelRequest(
    sessionID: chatSessionID,
    modelID: ready.model.id,
    messages: [AgentMessage(role: .user, content: "안녕하세요")],
    tools: []))

showAssistantMessage(turn.content) // 앱의 대화 UI 업데이트
```

다음 앱 실행을 위해 `providerID`와 `modelID`를 `ModelProviderSelection`으로 만들어 앱 설정에 저장하세요. 이 타입은 `Codable`입니다. 재실행 시 저장된 선택으로 runtime을 준비합니다.

```swift
let savedSelection = try ModelProviderSelection(
  providerID: ready.model.providerID,
  modelID: ready.model.id)
saveToAppSettings(savedSelection) // 앱의 설정 저장 코드

// 이후 앱 실행에서 provider와 카탈로그를 복원한 다음:
let access = try await providers.acquireRuntime(savedSelection)
let runtime = access.runtime
```

대화가 끝나거나 runtime을 교체할 때는 기존 access를 `try await access.release()`으로 해제하고 오류를 처리하세요. 종료는 설치된 모델 파일을 삭제하지 않습니다. LEAP과 MLX는 process 안에서 native 모델을 공유할 수 있으므로 runtime wrapper 종료와 모델 상주 메모리 해제는 같지 않습니다. 모델을 교체할 때는 [provider 수명 안내](../../Agent/NativeAgentPackage/docs/PROVIDERS.md#native-resource-lifecycle)도 따르세요.

설치된 파일을 지우는 일은 runtime 종료와 별개입니다. MLX connector에는 `removeModel(modelID:)`가 있습니다. 현재 LEAP·LiteRT Hub connector에는 같은 공개 삭제 API가 없으므로 파일을 임의 삭제하지 말고, 앱에서 지원한다고 안내하기 전에 해당 provider의 삭제 경로를 마련해야 합니다.

## 앱에 포함된 backend별 지원 형식

| Backend | 자동으로 찾는 파일 | 동작과 조건 |
|---|---|---|
| MLX (`mlx`) | MLX text policy에 맞는 `config.json`과 safetensors | 호환 파일을 설치하고 commit revision을 카탈로그에 보관합니다. 모델 아키텍처는 앱에 포함된 `mlx-swift-lm`이 지원해야 합니다. |
| LEAP / LFM (`leap-lfm`) | LFM2 text 모델의 GGUF | GGUF 하나를 선택합니다. 선호 순서는 Q4_0, Q4_K_M, Q4_K_S, Q5, Q8, 기타이며 같은 순위에서는 파일이 작은 쪽을 고릅니다. Audio/Vision 모델·부속 파일은 대상이 아닙니다. |
| LiteRT-LM (`litert-lm`) | `.litertlm` 파일 정확히 하나 | `CLiteRTLM` native backend를 포함한 iOS/macOS 빌드에서만 후보가 됩니다. |

모든 backend는 내려받을 revision을 고정 commit으로 해석합니다. MLX의 가져오기 전체 크기와 LEAP/LiteRT에서 선택한 파일에는 각각 8 GiB 상한이 있습니다. 파일 확장자는 후보 형식을 고르는 데 쓰이며, 실제 실행 가능 여부는 해당 native runtime이 판단합니다. 앱에는 필요한 디스크 공간과 네트워크 오류를 처리하는 UI가 필요합니다.

## 비공개 모델과 문제 해결

기본 설정은 공개 저장소용입니다. 비공개 또는 gated 저장소를 지원하려면 앱이 사용자 권한으로 인증된 Hugging Face client를 구성해야 합니다. LEAP과 LiteRT connector에는 `hubClient`를 전달하고, MLX는 인증된 `HubClient`를 사용하는 `MLXHubArtifactResolver`를 `MLXTextRuntime`에 전달합니다. 토큰을 앱 화면·로그에 노출하지 마세요.

| 사용자가 겪는 상황 | 앱에서 안내할 내용 |
|---|---|
| 지원 후보가 없음 | 선택한 저장소의 파일 형식·모델 구조를 앱의 포함 backend가 지원하는지 확인합니다. 주소만으로 새 native architecture를 추가할 수 없습니다. |
| backend 선택 요청 | 후보별 엔진과 다운로드 크기를 보여 주고 사용자가 선택하도록 합니다. |
| 비공개 모델을 읽을 수 없음 | Hugging Face 권한·로그인 상태를 확인하고 인증 설정을 안내합니다. |
| 저장 공간·다운로드 오류 | 남은 공간, 네트워크 연결, Hugging Face 접근 상태를 표시하고 재시도를 제공합니다. |

현재 선택된 앱 화면이나 iOS consuming app은 이 SDK 저장소에 포함되지 않습니다. 이 문서는 소비 앱에서 실제로 연결할 초기화·설치·선택·실행 흐름을 제공합니다.
