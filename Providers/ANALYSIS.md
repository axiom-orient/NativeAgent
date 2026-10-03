# MLX·LiteRT·LEAP native provider — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN. 확신도 중간: 호출/소유 구조, 실제 실행은 UNKNOWN.** 세 provider는 각자의 SDK/model format/I/O를 소유한 독립 optional library다. 공통 local-backend 수명 패턴과 다른 release 의미를 비교하기 위해 하나의 분석에 묶었다. 같은 실행 시스템으로 합친 것이 아니다. Apple/ChatGPT는 별도 분석이다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| MLX prepare/load/generate | host/connector → MLXTextRuntime / MLXTextModelClient | prepared artifact/model/config | MLX runtime resident + generation/result handle | runtime/event/native error | [Runtime.swift](MLX/Sources/MLXProvider/Runtime.swift); [MLXTextModelClient.swift](MLX/Sources/MLXProvider/MLXTextModelClient.swift) |
| MLX 공유 수명 | host → localBackend | 한 resident owner당 한 backend | LocalBackend load; MLXTextRuntime.unload 최종 release | 같은 ModelRuntime | [LocalBackendFactory.swift](MLX/Sources/MLXProvider/LocalBackendFactory.swift) |
| LEAP 다운로드/load/text | connector → LeapRuntime / ModelClient | model receipt/native runner identity | LeapRuntime runner + adapter/result handle | runtime/event/error | [Runtime.swift](LEAP/Sources/LEAPProvider/Runtime.swift); [ModelClient.swift](LEAP/Sources/LEAPProvider/ModelClient.swift) |
| LEAP 공유 수명 | host → localBackend | 한 runtime/준비 모델 바인딩 | LocalBackend → makeTextRuntime; unload | shared runtime / failure | [LocalBackendFactory.swift](LEAP/Sources/LEAPProvider/LocalBackendFactory.swift) |
| LiteRT C engine/session | host/connector → LiteRTProvider.loadRuntime | model/artifact/engine limits | runtime cleanup이 engine + lease release | runtime/cancel/drain error | [LiteRTRuntime.swift](LiteRT/Sources/LiteRTProvider/LiteRTRuntime.swift) |
| LiteRT 공유 수명 | host → localBackend | loaded runtime ownership | resident release closure는 비어 있음; runtime이 해제 | 중복 close 방지 | [LocalBackendFactory.swift](LiteRT/Sources/LiteRTProvider/LocalBackendFactory.swift) |
| Hub 설치 connector | HubModelInstaller → provider backend | repo/revision/file format/provider | 각 provider 다운로드·format 정책 | prepared descriptor | [ANALYSIS.md](../Model/ModelHub/ANALYSIS.md) |

## 실제 흐름

`host model/config → provider inspect/prepare → artifact lease → resident load → ModelRuntime → owned invocation/result handle → native settlement → runtime idle → [재사용] → host shutdown → unload/engine close`. SDK별 drain 방법은 해당 client/adapter에 남긴다.

`LocalBackendFactory`를 여러 번 호출하거나 standalone runtime API와 섞으면 같은 모델이 자동 dedup되지 않는다. 동일 handle을 하나의 host backend로 공유하는 것이 accepted 계약이다. Registry나 façade가 모델 이름으로 모든 resident를 강제로 합치지 않는다.

## 현재 state·contract·I/O owner

model artifact bytes는 ModelArtifactStore, native resident는 SDK별 runtime, invocation lane은 ModelRuntime, caller의 대화는 ModelSession/Agent가 소유한다. LEAP 공통 binary는 `NativeAILeapSDK` 한 manifest가 선언한다. binary identity 한 개는 runner 한 개라는 증거가 아니다. MLX와 hold의 pin 정렬은 source declaration 확인이지 remote resolution 성공이 아니다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 세 provider public 등록·loader | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — native dependencies/Metal/binary/model 필요 | 각 Package.swift·Sources |
| shared backend wiring | PUBLIC_LIBRARY | PARTIAL | PASS — common LocalBackend 계약; native release 미검증 | [ANALYSIS.md](../Model/LanguageModelRuntime/ANALYSIS.md) |
| LEAP binary 단일 선언 | REACHABLE | SATISFIED | PASS — source graph; binary link는 NOT_RUN | [Package.swift](LEAP/Packages/NativeAILeapSDK/Package.swift) |
| 실기기 generation/cancel/reuse/unload | REACHABLE | UNKNOWN | NOT_RUN — 각 native gate | DeviceQualification / provider tests |

## 실패·취소·복구 / findings

**F10 / 검증 gap.** runtime owner 분리는 타당하지만 actual native worker가 끝났는지 portable fixture로 증명할 수 없다. 기존 provider SDK pin/API를 최신화하면 검증 범위가 달라지므로 변경하지 않았다.

**판단:** 세 SDK의 loader/cache를 별도 새 Core singleton으로 통합하는 것은 더 좋은 단순화가 아니다. 공통 수명 계약은 유지하고 vendor의 실제 load/unload 메커니즘을 adapter에 남긴다. 오직 같은 concern/scope의 이중 release만 결함이다.

## Gap·검증·근거

각 provider의 `load → generate → cancel/drain → 재사용 → shutdown`, 부분 load 실패·late completion·기기 메모리 압박을 검증해야 한다. 세부 native 구현 전체의 내부 SDK thread/driver 동작은 미조사 외부 경계다. Xcode qualification consumers와 조건부 LiteRT manifest branch를 보존했다.
