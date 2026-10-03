# LEAP host 설정

이 문서는 LeapSDK를 실제 iOS app에 연결하는 consumer 절차다. provider behavior는 [PROVIDERS](PROVIDERS.md)와 package source, 실행 evidence는 [QUALIFICATION](QUALIFICATION.md)이 정본이다.

## 모델 준비와 호출

고정 파일·revision·크기·digest는 LEAPProvider source manifest가 소유한다. Host는 source manifest가 정의한 값을 사용하고, 외부 cached model을 import할 때 검증 결과를 확인한다. Agent 생성 자체가 download를 시작하지 않는 경로에서는 host가 prepare/import를 명시적으로 호출한다. 아래 코드는 host가 modelStoreURL, cachedModelDirectory와 dataStore를 준비했다고 가정한다.

```swift
import NativeAgent
import ModelArtifactStore
import LEAPProvider

let owner = LeapRuntime(store: try ModelArtifactStore(rootURL: modelStoreURL))
let prepared = try await owner.importModel(from: cachedModelDirectory)
let runtime = try await owner.makeTextRuntime(prepared)
let agent = try Agent(modelRuntime: runtime, storage: dataStore.storage)
let result = try await agent.run("Reply briefly.")
try await runtime.shutdown()
try await owner.unload()
```

오류·취소 경로에서도 stream drain과 wrapper shutdown 뒤 resident owner의 unload를 기다린다. Borrowed runtime을 닫았다는 이유로 resident가 해제됐다고 판단하지 않는다.

## iOS host integration

[sign_leap_embedded.sh](../scripts/sign_leap_embedded.sh)는 consumer app build의 Embed Frameworks 이후, 최종 CodeSign 전에 호출하도록 제공된 local signing helper다. 실행 결과를 실제 app bundle의 codesign check와 launch로 확인한다. Script 존재만으로 embedded SDK 서명이 성공했다고 보지 않는다.

Background download callback은 LeapBackgroundDownloads.handleEvents(for:completionHandler:)로 전달한다. Voice model, XcodeGen input과 실기기 test는 [LEAP DeviceQualification](../../../Providers/LEAP/DeviceQualification/README.md)에 있다. Text model, voice model, background completion, device process-death와 실제 audio quality는 각각 별도 qualification이다.
