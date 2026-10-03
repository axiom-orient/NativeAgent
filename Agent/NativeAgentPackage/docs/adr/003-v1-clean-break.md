# ADR 003 — 단일 현재 계약과 clean break

**상태: ACCEPTED.** 최초 2026-09-10, 개정 2026-09-13.

## 결정

- first-party persisted/wire 계약은 형식별 현재 writer와 reader 하나만 제공한다. 구버전 decoder, 자동 migration, 누락 필드 보정, 병렬 writer는 제공하지 않는다.
- first-party namespace는 `native-agent.*` / `NativeAgent`이고 JSON codec API는 `.nativeAgent()`다.
- Skill JavaScript 진입점은 `nativeAgentRun`이다. bridge/policy 문자열은 `WebKitSkillScriptContract`가 소유한다.
- 새 저장소의 bootstrap만 허용한다. 존재하는 미지원·불완전·손상 계약은 오류로 거부하며 원본을 변경하거나 삭제하지 않는다.
- 형식의 현재 버전은 독립적으로 관리한다. 현재 버전이 1이라는 사실만으로 서로 다른 Session, Memory, Skill, secret, model invocation authority를 합치지 않는다.
- 외부 MCP, SDK, 모델과 OS의 버전·wire 기능은 first-party 하위 호환 경로와 구분한다.

## Memory projection

SQLite schema 2만 읽고 쓴다. schema 1을 포함한 다른 버전은 journal mode를 바꾸기 전에 거부한다. 기존 데이터의 workspace identity, event, checkpoint, 원본 bytes는 그대로 남는다. 최초 schema와 identity 생성은 하나의 transaction으로 확정하며 실패하면 모두 rollback한다. durable generation과 forgotten source identity는 현재 계약의 기능이다.

## Model invocation

`native-agent.model-invocation/2` reference manifest와 `native-agent.model-turn/2` response receipt만 지원한다. 무버전 full-body 요청·응답을 읽는 recovery decoder는 없다. 누락·미지원 schema와 digest·session identity 불일치는 명시적 ledger 오류다.

요청 identity는 provider, snapshot revision, 현재 `ModelRequest`의 canonical encoding으로 계산하며 receipt envelope와 독립적이다. 동일 identity에 미지원 과거 receipt가 있으면 provider 호출 전에 거부한다. `started` 현재 receipt만 host가 명시적으로 완료·실패·재시도 판정할 수 있다. 오류를 새 요청으로 바꾸거나 알 수 없는 외부 효과를 자동 재실행하지 않는다.

## 요청과 Skills

`ModelRequest`의 output format, limits, output byte bound와 deadline은 현재 writer가 명시하며 decoder는 누락·null 값을 보정하지 않는다. Skills capability 요구값도 모든 필드가 명시되어야 한다. 선택적 모델 ID와 provider 응답 usage 등 실제 optional 값은 선택적으로 유지한다. 번들 Skills는 bundle resource root의 `skills/<group>/<name>/` 경로에서만 로드하며 평탄화된 대체 경로를 탐색하지 않는다.

## Managed Agent

Agent definition의 `knowledgeOwnership`, character profile의 `voices`, managed session의 response snapshot identity는 현재 계약의 필수 필드다. 필드가 없을 때 구형 의미를 추론하는 분기는 없다. 현재 character writer는 빈 `voices`도 명시적으로 기록한다. 새 Agent 생성 인자의 기본 response 설정도 `RESPONSE.json`에 명시적으로 저장하며, 기존 파일의 누락·손상은 모델 호출 전에 오류로 거부한다.

## 저장 root

기본 경로는 Application Support 또는 명시 App Group container 아래 `<appName>/NativeAgent/`이고 DB 이름은 `native-agent.sqlite3`다. `StoreLayout.defaultSubdirectoryName`이 기본 폴더명의 유일한 소유자다. 다른 제품의 저장 경로를 탐색·이동·읽기·삭제하지 않는다.

`rootURL`을 직접 주는 host는 전용 root를 제공한다. 미지원 데이터를 현재 저장소로 자동 전환하는 API는 없다. 기존 사용자 파일은 보존하며 지원되지 않는 상태의 원본을 새 root로 재지정하지 않는다. 모델 원본 파일의 명시적 import는 artifact 검증·복사 기능이며 session·skill·credential 데이터 이전 기능이 아니다.

## 수용 기준

현재 writer round-trip, missing/unsupported contract rejection, 최초 schema 생성 rollback, 동시 open identity 일치, 미지원 DB 원본 보존, 현재 model recovery와 미지원 receipt의 provider 실행 0회를 실제 테스트로 검증한다. 원본 데이터의 자동 변환이나 삭제는 clean break에 포함하지 않는다.
