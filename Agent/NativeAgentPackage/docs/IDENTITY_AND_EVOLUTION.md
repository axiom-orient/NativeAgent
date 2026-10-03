# NativeAgent — 정체성과 발전 원칙

## 정체성

provider-independent durable agent execution SDK다. caller는 저수준 Agent 또는 managed AgentManager를 조립하는 host다. 모델·도구 실행을 승인·effect identity·persistent state·recovery에 연결한다. UI, 계정, 모델 resident, knowledge 정본을 소유하는 앱은 비목표다.

## 변하면 안 되는 것

모델 출력과 실행 승인을 구분한다. 동일 request 의미·effect identity·revision·artifact reference를 보존한다. 시작한 효과의 불명확한 결과를 없었던 일이나 안전한 자동 replay로 처리하지 않는다. borrowed resource·사용자 데이터·runtime skill/resource와 public 계약을 보존한다.

## 변경 가능한 것

계약·데이터·권한을 유지하며 내부 coordinator, persistence adapter, provider, tool, Skills/Memory/Goals/Evolution/Consensus composition을 변경할 수 있다. 실제 consumer 필요 없는 새 manager/abstract wrapper는 추가하지 않는다. public API 변경은 명시적 계약 검토가 필요하다.

## 발전 방향

더 많은 자동 실행보다 명시적 승인과 정확한 effect 증거·복구를 우선한다. core는 provider/knowledge/UI에 독립적이며 선택 capability는 host composition으로 연결한다. 대화 편의 façade와 durable execution kernel을 같은 상태 owner로 합치지 않는다.
