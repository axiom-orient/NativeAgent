# ADR-0005 — 실행·대화·resident·외부 effect의 경계

- 상태: Accepted — 기존 경계 보존과 확인된 결함 수정. 새로운 공개 API/기능은 승인하지 않음.
- 날짜: 2026-09-20.

## 맥락

ModelExecutorStore/ModelRuntime/ModelSession/LocalBackend는 모두 상태를 갖지만 같은 material state의 중복 owner가 아니다. 반대로 buffered stream EOF는 provider producer/native 종료의 증거가 아니다. 취소 경계를 추가할 때는 아직 시작하지 않은 효과와 이미 완료한 write를 구분해야 한다.

## 결정

기존 다섯 영역과 public API를 유지한다. Core는 정확한 값 변환/진단 보존, Runtime은 admission·drain, Session은 대화 commit, store는 host config별 runtime 재사용, LocalBackend는 resident load/final release를 소유한다. façade는 위임만 한다.

registry는 취소된 획득 결과를 공개하지 않으며 늦은 owned resource는 정리한다. borrowed resource는 보존하고 cleanup failure를 cancellation으로 숨기지 않는다. Hub는 write 전 취소를 확인하고 반환 descriptor/provider를 검증하되 이미 관찰한 설치 결과를 취소로 지우지 않는다.

## 결과와 제약

역할이 다른 actor를 단일 manager로 합치거나 이름만 바꿔 중복 wrapper를 만들지 않는다. public port와 manifest는 보존한다. provider-owned completion 미결속은 별도의 구현 gap이며 이 결정만으로 해결되지 않는다.

cached runtime 직접 shutdown 뒤 자동 재생성, 원격 package 분리 배포, held API 제거는 결정 필요다. native/실서비스 증거 없이 승인하지 않는다. 현재 테스트 결과와 작업 이력은 ADR이 아니라 Current/verification/PLAN에 둔다.

2026-09-20 후속: ChatGPT owned completion 연결 구현은 [최신 검토](../REVIEW_20260920.md)를 따른다. 이 ADR 자체가 실계정·Apple native 증거를 제공하지 않는 원칙은 유지한다.
