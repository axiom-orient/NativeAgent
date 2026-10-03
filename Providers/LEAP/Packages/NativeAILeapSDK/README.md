# NativeAILeapSDK

`LeapSDK` upstream XCFramework의 **단일 SwiftPM binary declaration**을 제공한다. NativeAgent와 AppleLocalAI가 동일 URL/checksum을 각자 중복 선언하지 않도록 package identity만 공유한다.

이 package는 model download, runtime residency, inference, cancellation, unload authority를 소유하지 않는다. 각 consumer runtime이 자신의 lifecycle을 소유하며, NativeAgent와 AppleLocalAI가 같은 resident를 공유할 때는 workspace `LocalBackend` ownership을 사용한다.

정확한 version/checksum은 [`Package.swift`](Package.swift)가 정본이다. 현재 dependency는 prerelease snapshot이므로 실기기 link/sign/runtime qualification 없이 stable production status를 주장하지 않는다.

관련 문서: [workspace architecture](../../../../docs/ARCHITECTURE.md) · [Agent providers](../../../../Agent/NativeAgentPackage/docs/PROVIDERS.md) · [Apple LEAP package](../../../../MigrationHold/AppleLocalAI/Packages/AppleLocalAILEAP/README.md).
