# AppleLocalAI — Implementation Status

> 이 문서의 기존 상세 기록은 해당 subsystem 기준이다. 이번 리뉴얼의 최신 상태와 미검증 범위는 [workspace 검증](../../../docs/verification/README.md)이 소유한다. MigrationHold를 활성 완료 기능으로 해석하지 않는다.


기준일: **2026-09-20**.

| 영역 | 상태 | 비고 |
|---|---|---|
| AppleLocalAICore | 구현 | prompt/history/operation pure rules |
| AppleLocalAISession | 구현 | Foundation Models session wrapper |
| cancellation/late-result controller | 구현 | portable controller tests 존재 |
| LocalModels optional package | 구현 | CoreAI/MLX/LiteRT dependencies 선언 |
| LEAP optional package | 구현 | text/audio runtime, shared LeapSDK package 사용 |
| NativeAgent shared runtime bridge | 선택형 package에 구현 | `Packages/NativeAgentProviderAppleLocalAI`; root SDK는 이 package에 의존하지 않음 |
| Apple SDK 27 full build/test | NOT_RUN in current environment | Swift 6.2.1 Linux, package requires Swift 6.4 |
| actual local model inference | NOT_RUN | model/device/vendor runtime 필요 |
| LEAP physical-device signing/runtime | NOT_RUN | real iOS host 필요 |

Workspace shared backend 구현은 [`../../docs/IMPLEMENTATION_STATUS.md`](../../../docs/IMPLEMENTATION_STATUS.md)에 기록한다. 이 문서는 AppleLocalAI 자체 상태만 소유한다.

## 패키지 정리

`AppleLocalAI/Package.swift`는 독립 SDK 진입점이다. 선택형 adapter와 smoke qualification을 이 SDK 하위로 이동했다.
별도 Integration 제품은 없으며, 기존 독립 CoreAI/MLX/LiteRT/LEAP 경로는 보존했다.
이번 작업은 폴더·manifest 상대 경로·검증 도구·문서 변경이며 SDK source/tests는 변경하지 않았다.
최신 [실행 증거](../../../docs/verification/README.md)의 환경 제한을 따른다.
