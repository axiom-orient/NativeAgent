# AppleLocalAILocalModels

AppleLocalAI용 **선택 local-model adapter package**다. Root `AppleLocalAI`와 독립적으로 추가하며 CoreAI, MLX, LiteRT dependency를 이 package 안에 격리한다.

현재 dependency revision/version은 [`Package.swift`](Package.swift)가 유일한 정본이다. 모델 artifact의 실제 weights/export revision과 Swift source revision은 별도이므로 artifact hash를 따로 검증해야 한다.

이 package를 추가했다는 사실만으로 모델 download, runtime load, device compatibility 또는 inference 성공을 의미하지 않는다. 지원 SDK/device에서 실제 resolve/link/model test를 수행한다.
