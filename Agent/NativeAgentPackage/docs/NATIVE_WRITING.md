# iOS 네이티브 윤문과 캐릭터 대화

`NativeAgentManager`에 언어별 응답 지침, 캐릭터 프로필, Swift 보존 검사기가 포함된다. SwiftPM resource bundle에서 필요한 지침만 읽으므로 Python·셸·데스크톱 스킬 호스트를 설치하지 않는다. 최소 `NativeAgent` 커널은 이 리소스나 NaturalLanguage에 의존하지 않는다. 연구 근거와 도입 판단은 [RESPONSE_RESEARCH](adr/004-response-authority-and-preservation.md)에 있다.

## 기본 soul과 캐릭터

`SOUL.md`는 행동 원칙과 권한 경계다. `RESPONSE.json`은 별도의 캐릭터와 응답 설정이다. `createAgent`에서 soul을 생략하면 `AgentSoul.default`를 사용하며, 제공한 soul은 교체하지 않는다.

```swift
import NativeAgent
import NativeAgentManager

// manager와 selection은 호스트가 준비한 AgentManager / ModelProviderSelection이다.
let character = try AgentCharacterProfile(
  name: "루미",
  background: "달 도서관의 사서. 파란 수첩에 별 관측 기록을 남긴다.",
  personality: "호기심이 많고 신중하다. 모르는 것은 모른다고 말한다.",
  speakingStyle: "짧고 따뜻한 존댓말",
  relationship: "처음 찾아온 방문객을 안내한다.",
  scenario: "밤의 달 도서관",
  knowledgeBoundaries: "도서관 기록에 없는 과거의 일은 단정하지 않는다.",
  examples: [
    .init(language: "ko", user: "처음 왔어.", character: "어서 오세요. 어떤 이야기를 찾고 계세요?"),
    .init(language: "en", user: "I'm new here.", character: "Welcome. What kind of story are you looking for?")
  ]
)
_ = try await manager.createAgent(
  id: "lumi", name: "루미", provider: selection,
  response: .init(character: character, fallbackLanguage: "ko-KR")
)
let chat = try await manager.run(
  agentID: "lumi", input: "도서관에 처음 왔어.",
  metadata: AgentResponseOptions(language: "ko-KR").metadata
)
_ = try await manager.send(
  agentID: "lumi", input: "Tell me about your notebook.", to: chat.sessionID,
  metadata: AgentResponseOptions(language: "en-GB").metadata
)
```

배경·성향·말투·관계·장면·지식 경계가 실제 모델 요청에 들어간다. 대화 예시는 현재 언어와 맞는 것만 포함된다. 예시는 실제 대화 기록이나 동의가 아니다. 프로필에 `system_prompt` 교체나 도구 권한을 넣는 API는 없다. 모델에게 타인의 생각·선택·기억을 임의로 만들어 내지 않도록 지시한다. 이 지침의 존재만으로 모든 모델의 준수를 보증하지는 않는다.

언어마다 1인칭·호칭·존대가 다르면 `voices`를 지정한다. soul·성격·관계를 유지하면서 해당 언어의 말투만 구체화한다.

```swift
let multilingual = try AgentCharacterProfile(
  name: "루미", personality: "신중하고 호기심이 많다.", speakingStyle: "따뜻하고 간결하다.",
  voices: [
    .init(language: "ko", speakingStyle: "차분한 해요체 존댓말", selfReference: "저", addressForm: "방문객님"),
    .init(language: "en-GB", speakingStyle: "Gentle, measured British English", selfReference: "I", addressForm: "you"),
    .init(language: "zh-Hant", speakingStyle: "自然、溫和的繁體中文", selfReference: "我", addressForm: "您")
  ]
)
```

말투와 예시는 각각 **정확한 식별자 → 상위 식별자** 순서로 한 단계만 선택한다. `zh-Hant-TW`는 `zh-Hant-TW → zh-Hant → zh` 순서다. `en-GB` 요청에 `en-US` 예시를 넣지 않으며, `en`만 지정했을 때도 임의의 지역 예시를 고르지 않는다. 같은 단계의 예시가 여러 개면 모두 사용한다. `zh-TW`를 `zh-Hant`로 추론하는 기능은 없으므로 필요한 script를 명시한다. 식별자 비교에서 대소문자와 `_`/`-`는 동일하게 취급한다.

선택할 말투가 없으면 기존 `speakingStyle`을 사용하며, 다른 언어의 voice나 예시를 로딩하지 않는다. voice는 최대 8개이고 같은 정규화 식별자가 중복되면 실패한다. 기존 `RESPONSE.json`에 `voices`가 없으면 빈 배열로 읽는다. JSON의 잘못된 voice나 빈 말투를 정상 설정으로 조용히 바꾸지 않는다.

프로필은 JSON 인코딩 후 6 KiB, 예시는 최대 8개로 제한한다. 전체 추가 지침 기본 한도는 8 KiB다. 초과하면 `instructionBudgetExceeded`이며 캐릭터의 일부를 조용히 버리지 않는다. 설정은 `responseConfiguration` / `setResponseConfiguration`으로 읽고 바꾼다. soul, 캐릭터, 지침 버전이 바뀐 경우에는 새 세션을 시작한다.

## 언어 선택과 전용 스킬

| 네이티브 스킬 | 언어 | 역할 |
|---|---|---|
| `fluent-korean` | 한국어 | 새 설명·대화의 자연스러운 구성 |
| `koreanize` | 한국어 | 기존 원문의 윤문·표현 비교·국소 수정 |
| `english-polish` | 영어 | 같은 언어의 윤문, 지역·격식 보존 |
| `japanese-polish` | 일본어 | 경어·주체·추측·시제 보존 |
| `chinese-polish` | 중국어 | 간체/번체·지역 용어·부정·상 보존 |
| `spanish-polish` | 스페인어 | 지역어·호칭·법·의무/추정 보존 |

영어·일본어·중국어·스페인어에도 새 대화용 지침이 별도로 있다. `AgentNativeWritingSkill.available(for:)`는 지정 언어의 전용 스킬만 반환한다. `$koreanize` 같은 문자열을 원문에서 찾아 자동 실행하지 않는다. 호스트가 선택한 native API와 모드가 작업을 결정한다. 기존 일반 `SkillLibrary`에 설치한 도구 스킬과는 별개다.

대화 언어는 `AgentResponseOptions.language` → 현재 입력의 로컬 언어 인식 → 설정한 fallback 순서다. 높은 신뢰도로 감지한 **미지원 언어에는 다른 언어의 fallback 지침을 넣지 않는다**. fallback도 없고 판단이 불확실하면 언어 공통 지침만 사용한다. 언어가 바뀌면 이전 턴의 언어 지침은 다음 요청에 누적되지 않는다.

윤문에서는 명시 언어 또는 **원문**의 감지 결과를 사용한다. UI 언어·캐릭터의 언어·요청을 설명하는 문장의 언어로 원문 언어를 바꾸지 않는다. 윤문 언어가 불확실하면 `languageUndetermined`다. 여러 언어를 모두 다듬으려면 호스트가 편집 범위와 문맥을 나누어 각각 요청해야 한다. 한 요청 안의 통째 외국어 문단은 유지한다.

자동 인식은 `NLLanguageRecognizer`가 제공하는 상위 가설을 사용한다. 문자 12개 이상, 최상위 확률 0.8 이상, 다음 가설과 차이 0.2 이상을 현재 보수적 정책으로 정했다. 이는 연구에서 입증된 최적값이 아니다. 인식 대상을 지원 언어 5개로 강제 제한하지 않는다. `en-GB`, `zh-Hant-TW`, `ko_KR` 같은 식별자의 기본 언어를 선택하며 전체 BCP 47 레지스트리를 검증하는 구현은 아니다.

`compile(...).languageIdentifier`로 실제 선택된 식별자를 확인할 수 있다. 명시 언어뿐 아니라 감지·fallback의 script/region도 보존한다. 지원 언어가 선택되지 않으면 `nil`이다. 확실하게 감지한 미지원 원문의 윤문은 `unsupportedLanguage`로 실패하며, 불확실한 원문은 `languageUndetermined`로 구별한다. 이름 있는 윤문 스킬도 `writingRequest(..., language: "en-GB")`처럼 같은 언어의 지역 식별자를 받을 수 있다. `englishPolish`에 `ko`를 지정하는 요청은 거부한다.

NaturalLanguage는 텍스트의 언어를 분류한다. “한국어 문장으로 영어 답변을 요청한 의도”를 추출하는 기능은 아니다. 출력 언어가 입력과 다르면 호스트가 `language`를 명시해야 지침 선택도 정확해진다. 프로필의 다국어 원문을 번역해서 저장하지 않으며, 모델이 그 데이터를 이해하는지도 provider별 확인이 필요하다.

## 윤문과 Swift 검사

```swift
let request = try AgentNativeWritingSkill.koreanize.writingRequest(
  source: "이 변경은 지연 시간을 줄일 수 있습니다. 최대 3번 실행합니다."
)
let result = try await manager.runWriting(
  agentID: "lumi", request: request,
  anchors: ["줄일 수 있습니다", "최대 3번"]
)
// result.run.output: 실제 생성한 후보. 잘못된 결과도 숨기거나 자동으로 정리하지 않는다.
// result.preservation: Swift의 구조/보호문자열 검사 결과.
// result.languageCheck: consistent / different / unknown.
```

`runWriting`은 새 세션, `sendWriting`은 기존 세션을 사용한다. 일반 `run/send/queue/edit`에 `request.input`과 `request.metadata`를 함께 전달할 수도 있지만, 이 경우 자동 보존 검사는 없으므로 `AgentProseGuard.compare`를 호스트에서 호출한다. `choose`는 후보 선택 결과이므로 전체 원문과의 보존 비교가 적용되지 않아 `preservation == nil`이다. `replace`는 한 번만 나타나는 `target`을 요구한다.

```swift
let comparison = try AgentWritingRequest(
  source: "The algorithm uses little memory.", mode: .choose, language: "en",
  candidates: ["efficient", "effective"]
)
let replacement = try AgentWritingRequest(
  source: "The team carried out an inspection.", mode: .replace, language: "en",
  target: "carried out an inspection"
)
let report = AgentProseGuard.compare(
  source: Data("Wait at most 3 ms.\r\n".utf8),
  candidate: Data("Wait 3 ms.\r\n".utf8),
  anchors: ["at most"]
)
```

| 검사 상태 | 의미 |
|---|---|
| `MECHANICAL_PASS_SEMANTICS_UNVERIFIED` | 구현된 문자·구조 검사 통과. 의미와 문장 품질은 미검증 |
| `MECHANICAL_FAIL` | 검사한 보존 조건이 달라짐. 원문과 후보를 검토해야 함 |
| `UNSUPPORTED` | HTML/MDX·수식·불완전한 구분자 등 지원 범위를 벗어남 |
| `INPUT_ERROR` | UTF-8·입력 크기·anchor 오류 |

UTF-8 문자열과 Data를 받으며 파일을 읽거나 쓰지 않는다. Python 원본의 LF/CRLF, BOM, 마지막 개행, 빈 문단 구분, ATX/setext 제목, 한 줄 목록, 코드 펜스, 여러 백틱의 인라인 코드, 균형 잡힌 링크 목적지를 옮겼다. 표·인용 블록·front matter·들여쓴 블록은 통째로 보호한다. 숫자·일부 단위·링크·URL·인식 가능한 인용을 비교한다. Swift의 유니코드 정규화 동등성을 바이트 동일성으로 오인하지 않는다.

입력은 각각 256 KiB, anchor는 64개/합계 32 KiB까지다. `runWriting`은 잘못된 검사 입력을 모델 호출 전에 거부한다. 명명된 엔티티·숫자를 말로 쓴 표현·드문 단위·복잡한 인용·부정·인과·같은 구조의 문단 교환은 검사가 놓칠 수 있다. `Not all requests failed`가 `All requests failed`로 바뀌어도 anchor 없이는 기계 검사를 통과한다. 단어를 더 많이 바꾸거나 검사 점수를 높이는 것을 목표로 삼지 않는다.

호스트는 provider 실행의 `completed`와 편집 결과의 수용을 구분해야 한다. 보존 실패·미지원·언어 변경을 발견하면 후보를 검토 대상으로 표시한다. 기계 검사 통과 후에도 의미와 문체 검토가 필요하다. 반환값을 원본 파일에 자동 덮어쓰는 동작은 없다.

## 실행·복구 경계

```text
Native writing request / current user message
→ durable user input + per-message options
→ pinned Soul / response configuration / skill snapshot
→ turn prompt: common rules + one language + character OR editorial rules
→ request-only input rendering
→ compaction reservation + preservation of active source
→ exact ModelRequest validation + effect fingerprint
→ provider
→ durable actual result
→ Swift guard + dominant-language check (runWriting/sendWriting)
```

`polish`의 입력 JSON은 durable transcript에 그대로 남는다. 모델 요청에서는 현재 사용자 메시지만 원문 문자열로 렌더링한다. 모델이 입력용 JSON 형식을 답변에 모방하는 문제를 줄이기 위한 변환이다. 과거 메시지나 실제 provider 결과를 고치지 않는다. `choose/replace`는 후보와 target을 포함한 envelope를 전달한다.

`turnPromptAugmentors`는 세션 시작용 `promptAugmentors`와 다르다. 반복 모델 호출·도구 후속·재개에서도 durable baseline에서 요청용 지침을 만든다. `TurnInputProjector`는 현재 메시지의 모델 표시 형태를 소유하며, 두 projector가 동시에 그 메시지를 바꾸려 하면 실패한다. 추가된 지침의 대략적 토큰 비용을 compaction 예산에 반영하고, 최종 투영을 실제 요청 한도와 effect fingerprint에 포함한다. 현재 사용자 원문과 그 뒤 기록은 요약 대상에서 제외한다. 한도를 넘는 원문을 몰래 자르지 않는다.

응답 설정 SHA-256은 설정과 `AgentResponsePolicyLibrary.revision`을 묶어 세션에 고정한다. 정책·라우팅 의미를 변경할 때 이 revision도 올려야 한다. `RESPONSE.json`의 누락·잘못된 schema·손상·크기 초과는 오류로 거부한다. 필수 응답 정책 식별자가 없는 managed 세션도 모델 호출 전에 거부한다. 일반 Agent는 새 hook을 넣지 않는 한 기존대로 동작한다.

현재 정책 revision은 `native-agent.response-policies/2`다. 이전 정책 digest를 가진 세션을 계속 실행하면 `snapshotChanged`가 발생한다. 설정 파일의 schema는 `native-agent.response/1`을 유지하지만 새 정책을 쓰려면 새 세션이 필요하다. 이번 변경의 연구·검증·통합 경계는 [RESPONSE_REFINEMENT](NATIVE_WRITING.md)에 기록한다.

직접 `Agent`를 구성할 때는 `turnPromptAugmentors: [try AgentResponsePromptAugmentor(...)]`와 `run(..., requestMetadata: options.metadata)`를 사용한다. 이 경로에서는 호스트가 설정 버전 고정과 스킬 결과 검사를 책임진다. Manager의 일반 도구 스킬/승인 정책은 계속 별도 계약을 따른다. 내장 글쓰기 스킬 자체는 tool-call capability를 요구하지 않는다.

## iOS와 실제 모델 검증

라이브러리의 iOS 최소 버전은 17이다. NaturalLanguage와 Swift 검사기는 그 범위에서 사용할 수 있다. Apple Foundation Models 추론은 별도 provider의 iOS 26+·지원 기기·모델 준비 조건을 따른다. 내장 지침의 언어 지원과 모델의 언어 지원은 별개다. Foundation Models 호스트는 선택 locale을 `supportsLocale(_:)`로 확인해야 한다. [Apple 언어 지침](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)

현재 기능의 검증 기록과 원본 로그는 [RESPONSE_VERIFICATION](VERIFICATION.md)에 있다. macOS의 시스템 모델 결과를 iPhone 실기기 품질 인증으로 대신하지 않는다. 재현용 [ResponsePolicyQualification](../../../Qualification/ResponsePolicies/Package.swift)은 실제 모델을 사용하며 자동 의미 점수를 만들지 않는다.

```sh
NATIVEAGENT_LIVE_FOUNDATION=1 python3 scripts/verify_local.py \
  --evidence $TMPDIR/nativeagent-writing-proof --label live --timeout 600 -- \
  swift run --package-path Qualification/ResponsePolicies \
  --scratch-path $TMPDIR/nativeagent-writing-proof/build ResponsePolicyQualification
```

여기서 Python은 개발 Mac의 선택형 검증 실행 래퍼다. iOS 제품의 윤문·캐릭터·보존 검사에는 Python이 포함되지 않는다. 원본 스킬과 라이선스는 배포용 `Attribution.zip`에 보존하며 모델 컨텍스트에 로딩하거나 실행하지 않는다.
