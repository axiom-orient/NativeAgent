# NativeAILeapSDK

LEAP 0.11.0-SNAPSHOT의 검증된 `LeapSDK`와 `inference_engine` binary declarations를 소유한다. 현재 upstream release는 프리릴리스다. 하위 SDK 호환 경로는 없다.

SwiftPM product는 두 형제 framework를 함께 연결한다. SwiftPM/Xcode가 각 framework를 embed/sign하며, 이전 nested dylib 서명 script는 사용하지 않는다. Root Git 배포는 동일 URL/checksum을 그대로 선언한다.

이 package는 download, residency, inference, cancellation 또는 unload를 소유하지 않는다. 모델 수명은 LEAPProvider와 host LocalBackend가 소유한다. 정확한 URL/checksum은 [Package.swift](Package.swift)가 정본이며 실제 동작은 별도 검증한다.

The current root distribution requires Swift 6.3, iOS 26.5 and macOS 26.0. The official LEAP 0.11 inference_engine Mach-O declares these OS floors, despite the upstream package declaration; NativeAgent follows the actual binary. Independent MLX and LiteRT source packages retain their own supported OS floors.
