# ADR-0001 — native 공개 surface와 독립 제품 경계

상태: 기존 public boundary 보존. 날짜: 2026-09-19.

## 맥락·결정

native Foundation Models 타입을 public text API로 사용하고, Core는 순수 값·정책, local models와 LEAP는 선택 adapter로 둔다. LEAP native runner/Conversation은 text/audio runtime 밖으로 유출하지 않는다. sibling 실행 시스템을 이 SDK의 dependency로 넣지 않는다. 외부 Agent 연결은 해당 외부 adapter에서 수행한다.

## 결과

별도 transcript engine, 호환 alias, 두 번째 provider 구현을 추가하지 않는다. 기존 architecture guard의 negative checks는 실행 가능한 예전 기능이 아니라 재유입 방지 규칙으로 보존한다. model asset identity와 현재 public API·LICENSE·이식 source attribution을 유지한다.

외부 SwiftPM 소비자·이미 배포한 바이너리·영속 schema는 이 checkout만으로 열거할 수 없다. 따라서 외부 migration 완료 또는 데이터 이전 불필요를 선언하지 않는다. 공개 type 폐기·package 분할은 별도 영향 분석과 승인 대상이다. 취소·자산·동시성 구현 결함은 Current/PLAN에 남기며 문서 정리로 해결됐다고 보지 않는다.
