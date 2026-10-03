# AGENTS.md — AppleLocalAI

상위 [`../AGENTS.md`](../../AGENTS.md)를 먼저 적용한다.

## 제품 경계

AppleLocalAI root는 다음만 소유한다.

- Foundation Models session/profile/request projection.
- pure request/history/operation core.
- session-level cancellation and late-result protection.

다음은 root 책임이 아니다.

- MLX/CoreAI/LiteRT/LEAP dependency를 모두 강제 설치하는 것.
- model download/cache/resident의 전역 singleton.
- NativeAgent approval/effect journal.
- cloud/API-key fallback.

Vendor integration은 `Packages/AppleLocalAILocalModels`, `Packages/AppleLocalAILEAP` 또는 외부 integration package에 둔다.

## 수정 순서

1. `README.md`와 `docs/IDENTITY_AND_EVOLUTION.md`를 읽는다.
2. `Package.swift`와 실제 public source를 확인한다.
3. pure rule은 `AppleLocalAICore`, Foundation Models I/O는 `AppleLocalAI`에 둔다.
4. state는 enum/value type으로 표현하고 session operation owner를 하나만 둔다.
5. cancellation 후 late success가 현재 state를 덮어쓰지 못하게 한다.
6. vendor-specific code를 root target으로 끌어오지 않는다.

## 검증

Swift tools 6.4와 Apple SDK 27이 없으면 root full build는 `NOT_RUN`으로 보고한다. portable core/controller 검증만으로 Foundation Models API 성공을 주장하지 않는다.
