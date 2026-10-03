# ADR 0005 — Canonical trunk와 lifecycle 경계

상태: **부분 대체됨**. 원 결정 2026-09-17. ChatGPT package/조립/API 위치는 2026-09-19 [workspace ADR-0003](../../../../docs/adr/0003-split-chatgpt-text-image.md)이 대체한다. 아래 ASK/LEAP 권한 보존 결정은 유지한다.

## 맥락

선행 A/B 비교에서 optional package 누락, ChatGPT API 차이, 별도 LEAP host wrapper가 발견됐다. 해당 원본 A/B 자체는 현재 renewal 입력이 아니며, 그 비교 결과를 이번에 다시 실행했다고 주장하지 않는다. 지속되는 이유는 같은 상태 owner를 두 개 만들지 않는 것이다.

## 유지한 결정

NativeAgent kernel·ASK core·ModelHub·유효한 optional providers를 보존한다. image layers는 후보 생성이며 kernel의 승인·effect identity·artifact·복구를 대체하지 않는다. alpha 원본과 chroma projection을 구분하고 semantic fidelity를 구조 검사로 증명하지 않는다.

NativeAgent LEAP 경로는 `LeapRuntime`의 `empty/loadingVoice/loadingText/voice/text/draining/poisoned` 수명을 사용한다. 동일 scope의 `LeapModelHost`를 병렬로 추가하지 않는다. ModelHub/LEAPHuggingFaceModelProviderConnector의 취득·catalog와 resident lifecycle은 별개다.

## 대체된 결정과 영향

과거에는 Text factory가 Image capability를 포함하고 `installImageSkills`는 recipe 설치만 제어했다. 현재 clean break는 Image의 명시 등록과 `installDefaultSkills` 호출로 나눈다. 과거 플래그를 capability gating으로 재해석하지 않는다.

과거 `ChatGPTAccountSession.rateLimits()`의 의미·value types는 유지하되 위치는 `ChatGPTTextSession.rateLimits()`로 이동한다. OAuth/Keychain/refresh/sign-out 계약 변경 권한으로 확장하지 않는다. 구형 두 package 이름에 대한 compatibility wrapper를 남기지 않는다.

## 결과

인증은 Account, Text·Image는 독립 service, Agent 연동은 별도 adapter다. 각 concern에 하나의 owner를 두는 결정은 유지한다. 외부 AppleLocalAI의 전체 local backend와 NativeAgent backend를 합친 전역 owner 수렴까지 완료됐다는 뜻은 아니다.
