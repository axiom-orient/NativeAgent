# NativeAgentUI — ANALYSIS

## Verdict·책임 경계

**정체성:** agent 작업/사용량/설정 presentation 값과 선택 SwiftUI renderer.

**Caller:** Sumday JournalAIStyle/JournalAIViews/JournalAISettingsSurface 및 외부 SwiftUI host. **가치:** provider·제품에 종속하지 않는 표시를 제공한다.

**분석 분류:** 독립 분석 — 공개 계약/상태/I/O 또는 독립 build 경계를 소유하는 내부 배포 library. 별도 Sumday 앱으로 합치지 않는다.

**방향:** MAINTAIN. 제공된 새 SDK 밖의 앱 소유 독립 표시 package로 유지하며 공개 product와 구현은 보존했다. **확신도:** 중간: manifest·공개 구현·주요 caller를 확인했으며 실환경 결과는 별도 판정한다.

이 문서는 수정 후 Current다. 연결 상태와 계약 만족, 실행 검증은 독립적으로 판단한다. 전체 통합 판정은 [전체 Current](../docs/IMPLEMENTATION_STATUS.md)에서 소유한다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| presentation / public library | host→AgentUI contracts | readiness·availability·quota | immutable values | view input | AIContracts.swift |
| SwiftUI / Apple | host→AIWorkView/Settings | style+callbacks | renderer | user intent callback | AIWorkView.swift, AIStyle.swift |

## 실제 흐름

host immutable AgentUI value → NativeAgentPresentation → NativeAgentUI render → user callback → host effect. package View는 workspace·계정·generation I/O를 호출하지 않는다.

## 현재 state·contract·I/O owner

NativeAgentPresentation은 Sendable 값, NativeAgentUI는 그 렌더와 local interaction. provider status/quota는 host가 전달한 snapshot이며 credential authority가 아니다. 연결 여부만으로 image permission을 만들지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 공용 AI 화면 사용 | REACHABLE | PARTIAL | wiring 확인; native rendering NOT_RUN | JournalAIStyle.swift, AIContracts.swift |
| 외부 host presentation | PUBLIC_LIBRARY | SATISFIED | 실제 NativeAgentPresentation 테스트 4개 PASS; SwiftUI는 별도 | Package.swift/Tests |

## 실패·취소·복구·findings

### 1. UI library에 원문 권한 금지

문제 → 범용 컴포넌트가 앱 DB나 login을 소유하면 재사용 경계가 무너진다.

근거 → presentation/SwiftUI target 의존성

원인 → render input과 capability execution의 차이

영향 → TCA store 강제 반입 또는 service locator는 불필요

방향 → **MAINTAIN — local UI state와 callback 경계 유지**.

## 의존성·경계 판단

공개 product: `NativeAgentUI`, `NativeAgentPresentation`. manifest 평가 PASS는 package 선언이 해석된다는 증거이며 해당 제품의 build/test 성공이 아니다. 직접 package 의존성: 추가 package 없음.

## Gap·검증·근거

이번 전체 package test는 Linux에 SwiftUI가 없어 build 단계에서 중단됐다(NOT_RUN). SwiftUI 없는 앱/ASK에서 이 package를 끌어올 필요가 없다. 네이티브 시각/접근성 결과 NOT_RUN. optional UI products와 public prefix는 보존.

- [Packages/NativeAgent/UI/Package.swift](Package.swift)
- [Packages/NativeAgent/UI/Sources/NativeAgentPresentation/AIContracts.swift](Sources/NativeAgentPresentation/AIContracts.swift)
- [Packages/NativeAgent/UI/Sources/NativeAgentUI/AIStyle.swift](Sources/NativeAgentUI/AIStyle.swift)
- [Packages/NativeAgent/UI/Sources/NativeAgentUI/AIWorkView.swift](Sources/NativeAgentUI/AIWorkView.swift)

## 이번 범위의 구조 판단

MAINTAIN: 값·projection과 SwiftUI renderer가 target 수준에서 이미 분리되어 production 수정이 필요하지 않았다. root validation-only consumer가 실제 `NativeAgentPresentation`과 기존 4개 tests를 실행했다. 전체 package는 Linux에서 SwiftUI import로 build가 막혔으므로 native renderer의 결과는 NOT_RUN이다. render state를 계정/모델 authority로 바꾸거나 app Store를 SDK에 주입하는 리뉴얼은 하지 않았다.
