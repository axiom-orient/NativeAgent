# NativeAI — Production Readiness Research Pack

기준일: 2026-09-20

이 문서 패키지는 `NativeAI-OwnedCompletion-20260920` 저장소를 **실사용 가능한 상용 Swift AI runtime**으로 수렴시키기 위한 설계·검증·배포 기준이다. 구현 변경은 포함하지 않는다.

## 결론

NativeAI의 문제는 기능 부족보다 **지원 경계와 완료 증거의 불균형**이다. Core/Runtime은 비교적 정돈되어 있지만 provider, 계정, native resident, Agent/ASK, 이미지, MCP는 동일한 수준으로 검증되지 않았다.

최종 제품은 다음 4개 층만 권위 있게 유지하는 것이 가장 단순하다.

1. **Model Contract** — `LanguageModelCore`
2. **Execution Runtime** — `LanguageModelRuntime` + artifact/model install primitives
3. **Independent Capabilities** — Text provider / Image provider / Agent / Knowledge
4. **Host Composition** — 앱이 필요한 capability만 조립

`ChatGPT subscription`, `OpenAI API`, `Apple Foundation Models`, `MLX`, `LiteRT`, `LEAP`는 같은 종류의 backend가 아니다. 인증, 수명, 실행 위치, 보안, 완료 의미가 다르므로 provider별 qualification을 독립적으로 유지한다.

## 문서

- [PRODUCTION_BLUEPRINT.md](PRODUCTION_BLUEPRINT.md) — 목표 구조, public contract, lifecycle, provider 전략, 보안/운영/배포
- [QUALIFICATION_MATRIX.md](QUALIFICATION_MATRIX.md) — 기능별 Production 승격 조건과 A→Z 검증 시나리오
- [EXECUTION_PLAN.md](EXECUTION_PLAN.md) — 실제 구현 순서, clean-break/삭제 조건, 완료 정의
- [RESEARCH_SOURCES.md](RESEARCH_SOURCES.md) — 공식 자료와 설계에 반영한 사실

## 가장 중요한 판단

### 1. ChatGPT 구독 직접 provider는 Production 핵심 경로로 두지 않는다

OpenAI가 공식적으로 문서화한 ChatGPT 구독 통합 경계는 Codex CLI/App Server 계열이다. App Server는 인증, thread/turn lifecycle, approval, streamed agent events를 제공한다. 반면 모바일 앱이 ChatGPT 웹/내부 endpoint를 직접 호출하는 계약은 이 조사에서 공식 stable API로 확인되지 않았다.

따라서 현재 `Providers/ChatGPT/*`가 비공개/내부 서비스 프로필에 의존한다면 **Experimental**로 격리한다. Production cloud text/image가 필요하면 정식 OpenAI API를 별도 provider로 추가하되 모바일 앱에 API key를 탑재하지 않고 host backend를 통한다.

### 2. iOS 27+에서는 Apple Foundation Models를 기본 on-device façade 후보로 본다

Apple Foundation Models는 iOS/macOS의 on-device 모델뿐 아니라 `LanguageModel` protocol, Core AI 모델, MLX language model, Private Cloud Compute까지 같은 session API로 확장하고 있다. 그러나 기존 MLX/LiteRT/LEAP direct provider를 즉시 없애지 않는다. 기기 범위·모델 특화·성능·artifact ownership이 다르기 때문이다.

권장 구조는 **Apple Foundation Models adapter를 하나의 provider로 유지하고, direct MLX/LiteRT/LEAP는 각각 독립 provider로 유지**하는 것이다. 장래에 Foundation Models `LanguageModel` adapter로 감싸는 것은 성능·기능 parity가 실제 기기에서 증명된 뒤 선택한다.

### 3. Agent와 ASK는 Model Runtime의 하위 기능이 아니다

Agent는 approval/effect/recovery authority이고 ASK는 source/evidence/knowledge authority다. 둘을 Model provider 안으로 넣으면 domain transaction과 model execution lifecycle이 오염된다. integration은 adapter에서만 수행한다.

