# NativeAI — 정체성과 발전 원칙

## 정체성

NativeAI는 Swift 앱이 공통 모델 계약과 명시적 실행 수명 위에서 모델·Agent·지식을 조립하는 **독립 SDK/선택 adapter의 소스 묶음**이다. 단일 채팅 앱이나 모든 기능을 강제로 포함하는 umbrella package가 아니다.

caller는 앱 개발자와 외부 Swift package다. 핵심 가치는 모델 실행, 대화 기록, Agent 승인·효과 원장, 지식 정본, vendor I/O의 소유권을 구분하면서 함께 사용할 수 있게 하는 것이다. Host는 provider/계정/저장 위치/권한/수명/선택 기능을 명시한다.

NativeAgent는 durable execution, ASK는 source/evidence/approved knowledge, ASKTutor는 학습 domain이다. 모델 대화만 필요한 앱은 Agent/ASK 없이 ModelRuntime 또는 NativeLanguageModels를 사용한다. 모든 앱의 UI·계정·라우팅·작업 스케줄을 대신 결정하는 것은 비목표다.

## 변하면 안 되는 것

공통 request/event/schema 의미와 명시된 public contract를 보존한다. 허용된 과거 이름 변경은 [API_MAPPING](API.md)이 소유하며 임의 호환 wrapper를 만들지 않는다.

같은 material state/decision의 authoritative owner는 하나다. 실행 승인·원격 수행·local producer 종료·durable commit·resource release를 구분한다. 실패·취소·unknown outcome을 성공이나 안전한 자동 재시도로 바꾸지 않는다. borrowed resource를 해제하지 않고 승인되지 않은 mutation을 실행하지 않는다.

대화의 미확정 입력을 committed history로 노출하지 않는다. source identity/version/hash, knowledge receipt/journal과 Agent effect 기록을 보존한다. 파생 cache/projection은 정본이 아니다. runtime prompts/resources/skills와 LICENSE/NOTICE를 기능과 함께 보존한다.

## 변경 가능한 것

동일 public 의미·오류·권한·데이터 보존 조건을 지키면서 provider, 내부 상태 표현, 저장 메커니즘, UI, adapter, package 배치를 교체하거나 단순화할 수 있다. 구체 SDK는 core에 침투하지 않는다.

기존 API 이행은 실제 consumer와 capability parity를 검토한 명시적 결정이 필요하다. source package 분리와 독립 원격 배포는 다르며 version/URL/lockfile 계약은 별도 확정한다. 이 허용 범위는 새 기능·대규모 재설계의 자동 작업 권한이 아니다.

## 발전 방향

더 많은 계층보다 정확한 계약과 실제 효과의 관찰 가능성을 우선한다. 모델 선택→실행→종료, 승인→효과→증거, 원본→지식→파생 결과의 경계를 개선한다.

공통 core는 작게 유지하고 native provider·이미지·MCP·ASK/Agent 연결은 선택 adapter로 발전시킨다. 검증되지 않은 추상화보다 실제 consumer의 필요와 실행 증거를 우선한다. 전역 manager/server가 아니라 명시적 host composition으로 독립성과 연동을 함께 지킨다.
