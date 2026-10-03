# ADR-0001 — 독립 core와 단일 factual owner

## 상태

**Accepted — 2026-09-11; composition hierarchy amended by [ADR-0003](0003-agent-first-knowledge-capability.md) on 2026-09-13.**

## 맥락

NativeAgent는 session·model/tool effect·승인·cancel·recovery를 소유하고 ASK는 source·version·evidence·승인된 knowledge를 소유한다. 기존 구현에는 ASK FTS body shadow, Tutor Q/A dual write, NativeAgent invocation payload의 transcript 본문 중복, local memory와 외부 knowledge owner의 동시 활성 가능성이 있었다.

두 프로젝트를 합치거나 integration adapter를 추가하는 것은 이 중복 authority의 원인을 해결하지 않는다.

## 결정

1. NativeAgent와 ASK는 독립 public 제품으로 유지한다.
2. NativeAgent는 실행 truth를, ASK는 지식/evidence truth를 소유한다.
3. Soul은 정체성·행동 원칙, Skills는 실행 절차를 소유한다.
4. 동일 scope의 factual knowledge writer는 하나만 활성화한다.
5. NativeAgent profile은 `AgentKnowledgeOwnership.localCuratedMemory` 또는 `.externalKnowledgeBase` 중 하나다. external profile은 local `MEMORY.md`를 생성·읽기·쓰기·prompt 삽입할 수 없다.
6. ASK 검색 mirror의 본문 owner는 `search_docs` 하나이며 FTS5는 external-content derived index다.
7. tutoring learner/session/practice state는 ASKTutor가 소유하고 knowledge truth는 ASK가 소유한다. consumer가 NativeAgent를 generation mechanism으로 선택해도 NativeAgent transcript를 ASKTutor의 canonical state로 취급하지 않는다.
8. NativeAgent model invocation ledger는 execution identity/state와 content reference/digest를 소유하고 session transcript 본문을 다시 소유하지 않는다.
9. recovery는 reference를 hydrate한 뒤 ID uniqueness와 SHA-256/semantic digest를 검증한다. missing/mismatch를 최신 값이나 새 provider call로 조용히 대체하지 않는다.
10. 기존 invocation lookup key 의미는 이미 시작된 effect를 놓치지 않도록 유지한다. 이전 in-flight payload decoder는 safety-only read path로만 보존한다.
11. 범용 bridge, 양방향 memory sync, 공용 knowledge DB는 추가하지 않는다. Agent+ASK 조립은 [ADR-0003](0003-agent-first-knowledge-capability.md)에 따라 소비 애플리케이션이 직접 소유하는 얇은 capability mapping으로 제한한다.
12. SDK 저장소는 특정 제품 앱의 로그인·콜백·UI·lifecycle composition을 소유하지 않는다. 이러한 정책은 package consumer가 결정한다.

## 결과

각 제품은 독립적으로 사용할 수 있고, 함께 사용하는 host도 동일 factual content를 두 system에 canonical로 복제할 필요가 없다. 저장 최소화보다 더 중요한 것은 owner와 recovery 의미가 하나라는 점이다.

전역 transaction이나 universal exactly-once를 주장하지 않는다. NativeAgent effect와 ASK knowledge commit은 서로 다른 authority와 commit boundary다.

## 변경 가능한 것

FTS ranking, provider, UI, persistence mechanism, standalone local memory 사용 여부는 위 owner/invariant를 보존하는 한 교체할 수 있다.
