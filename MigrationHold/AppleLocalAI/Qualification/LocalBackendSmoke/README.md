# LocalBackendSmoke — 실제 모델 host 검증

하나의 LiteRT backend로 **AgentManager → AppleLocalAISession → AgentManager**를 실행한 뒤 host가 종료한다. [source](Sources/LocalBackendSmoke/LocalBackendSmoke.swift)와 [manifest](Package.swift)가 실행 계약이다. test-only model이나 SDK stub, 자동 download·server·fallback이 없다.

**현재 상태: NOT_RUN / SDK_ENV.** Swift 6.4+와 macOS 27 SDK/runtime, 호환 local `.litertlm` 모델이 필요하다. 모델 이름/크기만으로 호환성을 추정하지 않는다. 실제 model/source hash를 남긴다. iOS에서는 동일 composition을 app host에 연결하고 physical-device signing/lifecycle을 별도로 확인한다. 이 macOS executable이 iOS 검증을 대체하지 않는다.

```sh
# workspace root에서. 두 경로는 실제 caller 환경 값이다.
export LOCAL_MODEL_FILE='/actual/model.litertlm'
export LOCAL_STATE_DIRECTORY='/actual/new-directory'
swift build --package-path AppleLocalAI/Qualification/LocalBackendSmoke
swift run --package-path AppleLocalAI/Qualification/LocalBackendSmoke LocalBackendSmoke \
  "$LOCAL_MODEL_FILE" "$LOCAL_STATE_DIRECTORY"
```

state directory는 존재하면 거부한다. 기존 사용자 데이터를 덮어쓰지 않는다. 모델 파일은 기존 파일을 사용하며 sample이 내려받지 않는다. stdout 마지막 `Completed`는 세 번의 operation과 host shutdown이 모두 정상 반환한 경우에만 출력한다. operation과 shutdown이 모두 실패하면 두 오류를 보존한다. 이 문서에는 실행하지 않은 example output을 싣지 않는다.

먼저 `AppleLocalAI/Packages/NativeAgentProviderAppleLocalAI`의 실제 SDK tests와 `NativeAgentManagerTests`를 실행한다. 이후 native instrumentation으로 모델 load count와 메모리 residency까지 확인한다. 동일 Swift 객체 비교만으로 GPU 자원 수가 하나라고 증명하지 않는다.

MLX/LEAP host는 해당 prepared model을 기존 installer에서 얻은 뒤 각각 `mlxRuntime.localBackend(for: preparedModel)`, `leapRuntime.localBackend(for: preparedModel)`로 교체한다. 나머지 registry/Apple bridge 계약은 같다. 각각의 binary/dependency qualification은 여전히 따로 수행해야 한다.
