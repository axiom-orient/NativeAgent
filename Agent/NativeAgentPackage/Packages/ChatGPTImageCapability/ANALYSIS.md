# ChatGPT Agent 조립·이미지 capability — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN. 확신도 중간: explicit composition와 partial effect 분류, 실제 이미지 서비스 UNKNOWN.** ChatGPTAgent는 인증을 선행하는 managed factory, ImageCapability는 선택 도구·artifact projection이다. 둘은 provider credential 또는 text execution owner가 아니다. 공통 Agent-facing integration 경계로 포함해 분석한다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| text Agent factory | host → ChatGPTAgentFactory | account admission 먼저; 기존 service/skills 전달 | Manager.createAgent composition | managed Agent 또는 preflight error | [ChatGPTAgentFactory.swift](../ChatGPTAgent/Sources/ChatGPTAgent/ChatGPTAgentFactory.swift) |
| image tool 등록 | host → ChatGPTImagesCapability | explicit capability/router/policy | Agent tool registry / approval | image tool definitions | [ChatGPTImagesCapability.swift](Sources/ChatGPTImageCapability/ChatGPTImagesCapability.swift) |
| image generation/edit | Agent tool processor → ChatGPTImageExecution | 검증된 arguments/input artifact/limits | ChatGPTImageClient 외부 effect | tool result / before-dispatch failure / uncertain | [ChatGPTImageExecution.swift](Sources/ChatGPTImageCapability/ChatGPTImageExecution.swift) |
| artifact result | image executor → ToolResultBuilder | bytes/type/dimensions/publication | artifact store bytes; Agent refs | published result 또는 post-effect failure | [ChatGPTImageToolResultBuilder.swift](Sources/ChatGPTImageCapability/ChatGPTImageToolResultBuilder.swift) |
| layer/catalog/skill 선택 | host/model tool → layer/catalog/skill adapter | catalog asset/plan schema/feature activation | 선택 adapter projection | layer plan/verified result | [ChatGPTImageLayerTools.swift](Sources/ChatGPTImageCapability/ChatGPTImageLayerTools.swift); [ChatGPTImageSkills.swift](Sources/ChatGPTImageCapability/ChatGPTImageSkills.swift) |

## 실제 흐름

`host가 image capability 등록 → Agent schema/approval/effect-start → image arguments 검증 → account/client dispatch → bytes 관찰 → raster/PNG verification → artifact publication → ToolResult → Agent durable reference commit`. 이미지 생성과 저장 실패는 다른 effect 경계다. text factory는 image client/router/skills를 몰래 설치하지 않는다.

## 현재 state·contract·I/O owner

Account는 Providers/ChatGPT/Account, wire/network는 Image, permission/effect journal은 Agent, 이미지 format/layer/artifact mapping은 이 adapter가 소유한다. PromptSources→catalog/resources 생성 경로를 보존한다. generated assets를 source 없이 임의 수정하지 않았다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| text와 image 명시 조립 | PUBLIC_LIBRARY | SATISFIED | PASS — graph/source order; actual Manager 미실행 | [ChatGPTAgentFactory.swift](../ChatGPTAgent/Sources/ChatGPTAgent/ChatGPTAgentFactory.swift) |
| 이미지 tool/레이어/artifact 경로 | PUBLIC_LIBRARY | PARTIAL | NOT_RUN — live dispatch/Apple raster/Agent composition | [ChatGPTImageExecution.swift](Sources/ChatGPTImageCapability/ChatGPTImageExecution.swift) |
| resource/catalog/skill 보존 | REACHABLE | SATISFIED | PASS — 원본 byte 유지; 사용 성공과 별도 | PromptSources/Resources/SkillSources |

## 실패·취소·복구 / findings

서버가 이미 이미지를 만들었으나 저장/전달이 실패할 수 있다. 이를 단순 cancellation으로 덮어쓰거나 자동 생성 재시도로 바꾸면 중복 비용/결과가 발생한다. 기존 beforeDispatch/uncertain 경계는 보존한다. 구현을 보지 않고 “텍스트 provider 안의 이미지 기능 중복”으로 제거할 근거는 없다.

## Gap·검증·근거

live subscription 권한·계정 profile·서비스 응답 shape·실제 이미지 품질은 UNKNOWN. 이번 wire/local HTTP 44 tests에는 ImageClient나 이 adapter 전체가 들어 있지 않다. 전체 composition gate와 artifact write/reopen을 지원 환경에서 추가 검증해야 한다.
