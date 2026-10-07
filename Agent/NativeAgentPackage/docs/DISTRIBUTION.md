# NativeAgent Distribution

현재 NativeAgent root는 `Agent/NativeAgentPackage/Package.swift`다. Core/Runtime은 형제 `Model`에 분리됐다.
이 subtree만 단독으로 압축하면 상대 dependency가 빠진다. [workspace 배포 계약](../../../docs/PACKAGING.md)을 따른다.

이전 monolithic release script와 declarations는 사용자의 명시적 폐기 요청으로 제거했다. 검증한 root source revision을 수동 게시하며 CI/배포 자동화는 제공하지 않는다.
현재 release command로 실행하지 않는다. 모든 root product는 실제 Package.swift가 소유한다.
model/account/device qualification과 archive integrity는 별개다.
