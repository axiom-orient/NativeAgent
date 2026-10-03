# ADR-0003 — NativeAgent owns execution; consumer owns composition

- **Status:** Accepted
- **Date:** 2026-09-13

## Context

NativeAgent는 ASK 없이 실행 가능하고 ASK core도 NativeAgent를 import하지 않는다. 이전 first-party host(`ASKiPhone`, 이후 `NativeAgentApp`)가 SDK 저장소 안에서 composition root처럼 취급되어 **runtime authority와 distribution ownership을 혼동**했다. 또한 앱 내부 tutoring path가 ASK 기반 structured tutoring SDK와 별도 owner를 만들 위험이 있었다.

SwiftPM library product는 consumer가 dependency로 추가해 사용하는 배포 단위다. SwiftNIO와 TCA 같은 Swift library 프로젝트도 library와 example/application ownership을 구분한다. Agent 시스템에서도 retrieval/knowledge는 Agent에 장착하는 capability/tool로 두는 것이 자연스럽다.

## Decision

1. `NativeAgent`가 상위 execution runtime이다.
2. ASK는 optional knowledge capability다.
3. 제품 앱의 composition root는 **이 SDK 저장소의 소유가 아니라 consumer 책임**이다.
4. `Apps/NativeAgentApp` product/app는 제거한다.
5. 두 core는 서로 직접 의존하지 않는다.
6. Agent↔ASK same-process 연결은 consumer의 작은 ToolPack/closure typed adapter로 수행한다.
7. 별도 `Integrations/NativeAgentASK` package는 만들지 않는다. 동일 public glue가 실제 둘 이상의 consumer에서 반복될 때만 재검토한다.
8. `TutorEngine`은 `ASKTutor`로 명확히 이름을 바꾸고 production knowledge authority를 ASK로 고정한다.
9. ASKMCP는 external process boundary일 때만 사용한다.
10. Agent+ASK consumer adapter/example/composition root는 이 SDK 저장소가 소유하지 않는다. 결합 검증은 각 SDK의 public contract·dependency graph·소비자 제품 테스트에서 수행한다.

## Consequences

SDK와 제품 앱의 책임이 분리된다. NativeAgent-only, NativeAgent+ASK, ASK-only maintenance/test가 모두 명확해진다. 앱 전용 UI/lifecycle/backup aggregate state가 SDK public contract로 오염되지 않는다. ASKTutor가 tutoring domain의 단일 owner가 되며 demo-specific tutor state와 경쟁하지 않는다.
