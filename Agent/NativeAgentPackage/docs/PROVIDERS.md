# Provider와 외부 adapter 안내

이 문서는 host 개발자가 model, account, native resource와 remote tools를 연결할 때의 책임 경계를 정리한다. 선택 가능성은 live qualification 성공을 뜻하지 않는다. 해당 package manifest/source와 [qualification 절차](QUALIFICATION.md)가 원본이다.

## 선택과 호출

Host가 connector를 ModelProviderRegistry에 등록하고 invocation provider/model을 명시적으로 선택한다. Hugging Face 설치는 별도 [HubModelInstaller](../../../Model/ModelHub/README.md)가 등록된 backend의 파일 형식을 검사해 처리한다. Login, catalog lookup, model download와 native preparation은 factory/host I/O다. 이를 ModelRuntime reservation의 무효과 예약과 혼동하지 않는다.

```text
host selection/auth/prepare
→ connector.makeRuntime
→ runtime.reserve
→ durable model-started record
→ runtime.start and events
→ terminal/EOF/failure
→ cancel/drain and owner shutdown
```

Model-generated ToolCall은 Agent schema, approval, effect identity와 executor를 거친다. Provider가 tool을 직접 실행하거나 다른 account/model로 자동 대체하지 않는다. Runtime capability가 selected Skill/tool contract를 충족해야 한다.

## Provider 경계

| Adapter | 제공 경계 | 수명 owner |
|---|---|---|
| ChatGPT Text | TextSession metadata·ModelClient stream/tool/structured output. Image 자동 설치 없음 | Account가 credential/refresh, Text가 service state, Text adapter가 ModelRuntime 조립 |
| ChatGPT Image | 독립 raw generate/edit와 명시 Agent image capability | Account 공유, Image 요청 state 독립; kernel이 effect/artifact 소유 |
| MLX | MLX text file policy에 맞는 safetensors Hub repo 추가와 text generation. 실제 tool/structured support는 model specification과 template에 따른다. | host가 MLX resident를 unload; 작업 wrapper는 borrowed일 수 있음 |
| LEAP | LFM2 GGUF Hub 설치, text connector와 별도 voice API/model assets | provider runtime/host가 resident를 unload |
| LiteRT-LM | `.litertlm` Hub artifact 설치와 조건부 iOS native backend. Tool support는 artifact별 명시 opt-in | adapter가 engine lifecycle을 관리하고 invalidated engine을 reload |
| FoundationModels | 지원 OS/device에서 text generation. adapter가 광고하지 않는 tool/structured capability를 가정하지 않음 | 호출별 Apple session과 host lifecycle |
| MCP | remote tool transport adapter; model provider가 아님 | host가 transport, authentication, reconnect와 shutdown을 소유 |

각 product의 정확한 dependency와 activation condition은 manifest와 source에 따른다. [ChatGPT account 사용](../../../Providers/ChatGPT/Account/README.md), [ChatGPT Agent adapter](../../../Providers/ChatGPT/TextProvider/README.md), [LEAP host 설정](LEAP_DEVICE_SETUP.md)과 [LEAP voice qualification](../../../Providers/LEAP/DeviceQualification/README.md)을 참조한다.

소비 앱의 의존성 연결부터 URL 입력·진행률 UI·backend 후보 선택·설치된 모델 호출·재실행 복원까지는 [Hugging Face 주소로 앱에 모델 추가하기](../../../Model/ModelHub/README.md)를 따른다. `HubModelInstaller`는 설치 시 호환 형식을 검사하며, 한 backend만 맞으면 설치와 runtime 준비를 이어 준다. 후보가 여럿이면 앱이 사용자 선택을 받아야 한다. 설치 시 형식 선택과 호출 시 model selection은 별도 단계다. 호출 registry는 다른 backend로 fallback하지 않는다. 앱에 포함되지 않은 새 native model architecture는 주소만으로 추가되지 않는다.

## Native resource lifecycle

LEAP/MLX wrapper shutdown은 공유 resident unload와 같지 않다. 작업 취소 뒤 consumer는 stream drain을 기다리고 resident owner의 unload 결과를 확인한다. Artifact lease, resident gate, cleanup uncertainty를 무시하고 새 load를 시작하지 않는다.

LiteRT처럼 adapter가 native engine을 직접 소유하는 경우 cancel 뒤 엔진은 무효화될 수 있어 새 load가 필요하다. FoundationModels readiness도 OS/device availability와 model 준비에 따라 달라진다. 이 조건은 consumer가 실행 환경에서 확인한다.

## 계정·이미지·도구 권한

OAuth/credential/catalog/refresh/transport와 Agent approval/effect/artifact publication은 서로 다른 owner다. Image response 구조 판정과 실제 user request 충족도 구별한다. 진단 artifact가 저장되어도 structural_only 또는 needs_repair를 성공으로 읽지 않는다. Correlation ID는 remote exactly-once 증거가 아니다.

MCP의 read-only metadata는 Agent approval 면제가 아니다. Remote auth, HTTP binding, cancellation notification, peer process와 reconnect 정책은 host가 구성한다. MCP package와 ASK MCP에는 서로 다른 권한 domain이 있으므로 혼동하지 않는다.

## Dependency pin

Provider 버전과 revision은 해당 Package.swift 및 Package.resolved가 소유한다. 이 문서에 pin 값을 복제하지 않는다. Source pin과 consumer environment qualification은 서로 다른 정보다. 지원 환경의 test 절차는 [QUALIFICATION](QUALIFICATION.md)을 따른다.
