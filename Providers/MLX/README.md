# Hugging Face MLX 모델을 앱에서 추가하기

## Shared backend composition — 2026-09-19

Use `localBackend(for:)` once per host-selected prepared model. Frontends borrow the same ModelRuntime; only the host LocalBackend shuts it down. Dependencies are exact current releases: MLX Swift 0.32.3, MLX Swift LM 3.32.3, Hugging Face 0.13.0 and Transformers 1.3.4. No older-library fallback or migration package is provided. The root Git package exports MLXProvider and MLXModelRegistry directly.

`MLXProvider`는 앱 배포 후에도 사용자가 Hugging Face 모델 주소를 붙여 넣어 MLX 모델을 추가할 수 있는 SDK 경로를 제공합니다. 이 저장소에는 소비자 앱 UI가 없으므로, 앱은 주소 입력란과 아래 SDK 호출을 연결하면 됩니다.

## 공급자 한 번 등록, 모델은 필요할 때 추가

앱 시작 시 영구 저장 위치를 정하고 connector를 한 번 등록합니다. 모델 추가 화면은 받은 주소를 `installModel(from:)`에 전달합니다.

```swift
import ModelArtifactStore
import LanguageModelRuntime
import MLXProvider

let modelRoot = applicationSupport.appending(path: "MLXModels", directoryHint: .isDirectory)
let store = try ModelArtifactStore(rootURL: modelRoot)
let mlx = MLXTextRuntime(
  store: store,
  specificationsPersistenceURL: modelRoot.appending(path: "model-catalog.json"))
let mlxProvider = try MLXHubModelProviderConnector(runtime: mlx)

let providers = try ModelProviderRegistry()
try await providers.register(mlxProvider)

// Call from the app's “Add model” action with the pasted URL.
let model = try await mlxProvider.installModel(
  from: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit",
  progress: { progress in
    print(progress.completedBytes, progress.totalBytes, progress.currentFile ?? "")
  })

// It is now listed and can be selected immediately; this install is the current-session default.
let availableModels = try await providers.models(providerID: "mlx.text")
let selection = try ModelProviderSelection(providerID: "mlx.text", modelID: model.id)
let runtime = try await providers.makeRuntime(selection)
```

`installModel` resolves a branch/tag to its current 40-character commit, downloads the approved files, verifies and atomically publishes them, then records the model in the connector catalog. The commit—not a moving `main` reference—is saved, so the app can restore the catalog after relaunch. `ModelProviderRegistry` then creates the selected runtime without rebuilding or shipping a new app version.

The same URL can be installed again to pick up a newer branch head. Each commit is a separate model entry; older entries remain available until the host calls `removeModel(modelID:)`.

The connector keeps its default selection in memory. The host should persist the selected `model.id` in its own settings and pass it as `defaultModelID` on the next launch, or use an explicit `ModelProviderSelection` as in the example.

For a host that does not need provider discovery, `try await mlx.loadRuntime(from: address)` combines resolution, download, and model loading into one call.

## 지원 범위

- 주소는 `namespace/repository`, `https://huggingface.co/namespace/repository`, `/tree/<revision>`, `/commit/<sha>` 형식입니다. 다른 호스트, query parameter, 파일 링크는 거부합니다.
- 기본 경로는 공개된 Hugging Face 모델을 사용합니다. 비공개·gated 저장소는 앱이 인증된 `HubClient`를 만들고 `MLXHubArtifactResolver(hubClient:)`로 주입해야 합니다. 이 경우 앱 target에 `swift-huggingface`의 `HuggingFace` product도 직접 추가합니다.
- MLX용 `config.json`과 `safetensors`가 있는 모델 저장소가 대상입니다. Python 실행 파일, 임의 model code, PyTorch pickle은 내려받지 않습니다. 내려받은 weight만으로 새 MLX 아키텍처가 추가되지는 않으므로, 현재 앱에 포함된 `mlx-swift-lm`이 해당 모델 구조를 지원해야 합니다.
- 모델 파일 저장소와 `specificationsPersistenceURL`은 앱의 영구 저장소에 두어야 재시작 후 목록과 오프라인 실행을 유지할 수 있습니다. 모델 저장 공간과 사용자가 수락해야 하는 모델 라이선스 안내는 앱이 관리합니다.

`MLXProviderConnector`는 빌드 시 준비한 고정 목록을 위한 기존 API입니다. 사용자 입력으로 모델 목록을 늘릴 앱은 `MLXHubModelProviderConnector`를 등록합니다.
