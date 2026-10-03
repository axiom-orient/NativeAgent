# ADR004 — 응답 지침과 원문·실행 권한의 분리

상태: **기존 확정 규범의 정리**. NativeAgent SPEC·ARCHITECTURE·NATIVE_WRITING과 현재 공개 API의 결정 맥락을 통합한다. 이번 검토의 새 구현·schema·외부 카드 호환·자동 기억 생성 승인은 아니다. 기준 2026-09-11.

## 맥락

캐릭터 대화, 새 응답 작성, 이미 쓴 문장의 윤문은 보존 대상이 다르다. 캐릭터의 말투를 사용자 문서에 덧씌우면 원문 계약을 깨뜨린다. UI 언어·원문 언어·목표 언어도 같다고 가정할 수 없다. 검색된 지식·역할 예시·외부 프로필 데이터는 실제 기억이나 도구 권한이 아니다.

세션 시작 지침만으로 현재 turn의 언어/작업을 모두 표현하지 않으며, provider 직전의 숨은 입력 변경은 검증·effect fingerprint와 어긋날 수 있다. durable 원문을 보존하면서 모델에 보여 주는 표현을 별도로 구성해야 한다.

## 결정

- soul/프로필·사용자 설정·curated facts·session 원문·현재 응답 지침의 owner를 구분한다. profile 예시나 상상한 사건을 실제 기억으로 승격하지 않는다. 외부 Character Card의 system override·템플릿·lorebook을 실행 권한으로 사용하지 않는다.
- 캐릭터 대화와 윤문을 별도 작업으로 다룬다. 윤문은 의미·강도·주체·보호 대상·원문 목소리를 보존하며 번역·요약·내용 확장·새 persona를 몰래 수행하지 않는다.
- 명시 목표 언어를 보존하고 필요한 언어 resource만 선택한다. 짧은/혼합/코드 입력의 감지는 불명확할 수 있다. 편집 원문을 임의 fallback 언어로 확정하지 않는다. 바이트 예산을 모든 모델의 토큰 예산과 같다고 보지 않는다.
- model-facing 현재 turn projection은 durable 원문을 바꾸지 않으며 요청 검증과 fingerprint 전에 반영한다. 순수 projector에 검색·network·파일 쓰기를 숨기지 않는다. 실제 hook의 호출 조건은 [Native writing 안내](../NATIVE_WRITING.md)와 public source를 따른다.
- Swift 기계 검사는 protected text·구조·확실한 언어 변화의 진단이다. `mechanicalPassSemanticsUnverified`는 의미 동등성·문학적 품질·캐릭터 일관성의 인증이 아니다. 모델 자신의 평점도 독립 정답이 아니다.

## 결과·보존 조건

Host 사용법과 export 실행 명령은 [NATIVE_WRITING](../NATIVE_WRITING.md), 호스트 안내는 [NATIVE_WRITING](../NATIVE_WRITING.md), 실행 기록은 [VERIFICATION](../VERIFICATION.md), 실제 model/device procedure는 [QUALIFICATION](../QUALIFICATION.md)을 따른다.

Prose Polish Suite의 원본 정책·guard·저작권/attribution 자료는 [sources](../sources/prose-polish-suite/SOURCES.md) 아래 그대로 보존한다. 실행용 resource·skill·fixture와 설명 문서의 정리는 다른 작업이다. UTF-8 보호와 BOM/구조 검증의 정확한 의미는 [원본 guard 계약](../sources/prose-polish-suite/references/guard-contract.md)과 실제 Swift 구현을 따른다.

## 기존 결정에 사용된 참고 자료

다음은 통합한 이전 문서가 사용한 참고 자료다. 이번 코드/현재 모델 실행의 증거가 아니며 날짜·수치·최신 모델 품질을 재인증하지 않는다. 작은 모델에 논문의 학습/평가 결과가 그대로 적용된다고 주장하지 않는다.

| 1차 자료 | 보존한 판단·제한 |
|---|---|
| [Apple TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) · [언어/locale](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models) · [NLLanguageRecognizer](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer) | 문맥 예산·언어 감지와 의도 구분. 특정 시스템 모델의 한도를 다른 provider에 일반화하지 않음 |
| [RFC 4647 §3.4](https://www.rfc-editor.org/rfc/rfc4647.html#section-3.4) · [Agent Skills](https://agentskills.io/specification) | 언어 태그 선택·필요 자료만 로딩. 지침과 실행 환경은 다름 |
| [RoleLLM](https://arxiv.org/abs/2310.00746) · [InCharacter](https://aclanthology.org/2024.acl-long.102/) · [CoSER](https://arxiv.org/abs/2502.09082) | 말투·역할 지식·성격·평가 조건 구분. 모바일 다국어 품질 보증 아님 |
| [Character Card V3](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md) | 교환 데이터와 system/실행 authority를 구별. 전체 import/export 호환을 승인하지 않음 |
| [TETRA](https://aclanthology.org/2024.bea-1.21/) · [로컬 보존 계약](../sources/prose-polish-suite/references/core.md) | 가능한 편집의 다양성과 기계 검사 한계. 단일 정답 문자열만으로 의미 판정하지 않음 |

참고 자료는 결정의 배경이며 현재 모델 품질이나 실행 성공을 증명하지 않는다. 실제 host/device gate는 [QUALIFICATION](../QUALIFICATION.md)에서 수행한다.
