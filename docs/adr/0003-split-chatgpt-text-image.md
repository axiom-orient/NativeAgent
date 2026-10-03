# ADR-0003 — ChatGPT service 분리와 explicit host composition

상태: **Accepted** — 사용자가 첨부 검토 문서에 따른 리뉴얼과 기존 auth 보존을 요청했다. 이 결정은 package/API 소유권 분리를 승인하며 native backend pin 교체까지 승인하지 않는다.

## 맥락

하나의 구독 SDK에 계정·catalog·SSE·이미지가 섞였고, Agent factory가 Text 선택에 image client/capability/router/skills를 자동 설치했다. raw Image payload가 ModelCore를 사용하고 Image codec가 Text helper를 공유했다. 이름만 바꾸는 target 분리는 실제 dependency/resource 결합을 해결하지 못한다.

## 결정

공통 `ChatGPTAccount`, 독립 `ChatGPTText`/`ChatGPTImage`, 얇은 `ChatGPTTextProvider`/`ChatGPTImageCapability`를 사용한다. Text↔Image 직접 의존과 Text factory의 자동 image 설치를 제거한다. host가 같은 Account actor를 전달하고 image capability/router/skills를 명시 등록한다.

로그인·PKCE·callback·Keychain·refresh는 기존 구현을 유지한다. protocol profile의 기존 public 상수는 Account에 유지한다. model metadata/quota/selection은 TextSession으로 이동한다. service SPI는 account-scoped access lease/transport만 제공하며 refresh/id token은 내보내지 않는다.

Apple Core/Session root에서 LocalModels/LEAP의 vendor manifest를 분리한다. source/public module 이름과 pin은 보존하고 consumer가 optional package를 선택한다. 이것은 Native/Apple backend 전역 단일 owner를 구현했다는 결정이 아니다.

## 명시적 clean-break migration

| 이전 | 이후·보존 의미 |
|---|---|
| `import NativeAgentChatGPTSubscription` | 사용하는 기능별 `ChatGPTAccount`, `ChatGPTText`, `ChatGPTImage` import |
| `ChatGPTAccountSession.beginSignIn/completeSignIn/cancelSignIn/status/signOut` | 이름·호출 의미 유지, import만 Account |
| `account.models/resolvedModel/rateLimits` | `ChatGPTTextSession(account: account).models/resolvedModel/rateLimits`; 재사용 session은 host/connector가 소유 |
| `ChatGPTModelClient(account:...)` | 같은 공개 이름·account convenience 보존; TextSession 공유 init 추가 |
| `ChatGPTImageClient(account:...)` | 같은 이름/연산 보존, raw bytes 타입은 `ChatGPTImageContent` |
| raw image request/result의 `ModelBinaryContent` | `ChatGPTImageContent(mimeType:data:filename:)`. Agent layer 공개 `ModelBinaryContent`는 유지, adapter에서 변환 |
| `import NativeAgentProviderChatGPT` | Text runtime/factory는 `ChatGPTTextProvider`; image는 `ChatGPTImageCapability` |
| factory `installImageSkills` 및 자동 image 연결 | 삭제. `additionalCapabilities`, `skillIntentService`, `ChatGPTImageSkills.installDefaultSkills`를 host가 명시 호출 |
| Image 코드의 `ChatGPTRuntime.providerID` 의존 | `ChatGPTImagesCapability.providerID`; 문자열 `chatgpt.subscription` 보존 |
| `AppleLocalAI` root의 LocalModels/LEAP products | 같은 product/module 이름을 `AppleLocalAI/Packages/AppleLocalAILocalModels`, `.../AppleLocalAILEAP`에서 선택 |

## 결과·보존 조건

이전 두 통합 package wrapper는 남기지 않는다. 외부 caller는 위 import/metadata/raw-payload 이동을 적용해야 한다. source/module 분리 때문에 native 전체 qualification은 필수이며 과거 통합 package PASS를 새 package의 PASS로 사용하지 않는다.

실제 service model identity/tool/schema/approval/artifact/failure 의미, optional layer/catalog/skill 기능, runtime resources, LICENSE/NOTICE를 보존한다. binary pin 충돌이나 shared residency는 별도 backend 결정으로 다룬다. auth 동작을 바꾸는 후속 작업은 이 ADR의 승인 범위가 아니다.

## LEAP 바이너리 공통 배포 경계

사용자의 backend owner 수렴 요구 중, 두 frontend가 선언한 동일 `LeapSDK` URL·checksum을 `NativeAILeapSDK`의 한 binary target으로 통합한다. LEAPProvider와 AppleLocalAILEAP는 같은 `LeapSDK` product를 의존한다. 기존 SDK version/checksum·module name·각 public runtime API는 보존한다.

이 결정은 package/binary identity의 단일 owner만 확정한다. model install/cache/residency/cancellation owner 통합, MLX exact pin 충돌, 두 runtime의 실제 공존은 별개 조건이다. 단일 바이너리 선언을 단일 native runtime 증거로 간주하지 않는다. 기존 sealed-source 배포 루트에 공통 manifest를 넣어 local dependency가 배포 밖으로 탈출하지 않게 한다.
