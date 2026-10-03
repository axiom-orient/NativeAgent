# ASK — IMPLEMENTATION_STATUS

## 제품·범위

이 제품의 actual caller·flow·state/I/O owner·capability·findings는 [상세 ANALYSIS](../ANALYSIS.md)가 소유한다. 상위 package collection의 현재 변경·환경·전체 graph는 [workspace Current](../../../docs/IMPLEMENTATION_STATUS.md)를 따른다. 독립 제품을 단일 Agent/모델 시스템으로 합치지 않는다.

## 현재 상태·검증

root ASKClient의 plan/dryRun/apply/query와 mutation lease→canonical journal→derived presentation 경로를 추적했다. ASKAgentTools integration 실행은 swift-markdown repository resolve에서 차단됐다. KnowledgeCore/KnowledgeRuntime의 실제 local tests와 root/Agent integration gate는 별도다.

ASK production source·manifest·tests는 변경하지 않았다. projection/index가 canonical journal을 대체하지 않고 Tutor/MarkdownWiki/Document의 별도 domain도 보존한다.

## 근거·남은 작업

[현재 실행 증거](../../../docs/verification/README.md)에서 명령·exit·로그·source hash·제외 범위를 확인한다. 과거 문서의 PASS를 현재 검증으로 승계하지 않는다. 필수 native/외부 검증이 남은 항목은 [PLAN](PLAN.md)에서 유지한다. 정체성·SPEC·ARCHITECTURE는 현재 테스트 결과와 분리한다.

## 이번 local 검증

원본 `KnowledgeCore` manifest에서 36 tests, `KnowledgeRuntime` manifest에서 109 tests를 실행해 통과했다. [현재 로그·source hashes](../../../docs/verification/imported-baseline/production-refactor-20260920/knowledge-local.json)가 적용 범위를 소유한다. 이 결과는 ASK root/Agent 승인 통합·외부 서비스·실제 OS crash durability의 PASS가 아니다.
