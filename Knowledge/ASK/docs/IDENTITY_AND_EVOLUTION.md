# ASK — 정체성과 발전 원칙

## 정체성

문서 source·원문 근거·승인 지식과 journal을 관리하는 독립 local-first headless knowledge SDK다. caller는 ASKClient를 구성하는 앱·도구·Agent adapter다. source identity와 evidence를 잃지 않고 명시적 proposal/decision으로 지식을 축적하는 것이 가치다. Agent 실행 원장·UI·계정의 주인은 아니다.

## 변하면 안 되는 것

source/version/range/hash와 canonical patch/receipt/CAS/replay 의미를 보존한다. projection·검색 결과·모델 평가를 승인된 지식 정본으로 승격하지 않는다. root query는 숨은 write/repair를 만들지 않는다. mutation의 실제 footprint·승인·partial/unknown outcome과 데이터 보존을 지킨다.

## 변경 가능한 것

source/evidence/knowledge 권한과 public 계약을 유지하며 parser, index, runtime mechanism, 저장 adapter, UI, MCP/model integration을 교체할 수 있다. 독립 Tutor/wiki/document domain을 이름만으로 병합하지 않는다. scope별 writer·receipt 의미 변경은 명시 결정이 필요하다.

## 발전 방향

원문 근거에서 승인된 지식과 파생 결과로 가는 명시적 흐름, 정확한 재현·조회·복구를 우선한다. Agent 연결은 선택 adapter이며 ASK core의 필수 의존성이 아니다. 새 복제 정본보다 기존 canonical owner와 typed contract의 일관성을 강화한다.
