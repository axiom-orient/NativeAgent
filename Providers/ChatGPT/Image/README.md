# ChatGPTImage

Text·SSE·model catalog·ModelCore·ModelRuntime에 의존하지 않는 raw 이미지 service SDK입니다. 유일한 공통 service dependency는 [Account/Auth](../Account/README.md)입니다.

```swift
import ChatGPTAccount
import ChatGPTImage

let client = try ChatGPTImageClient(account: account)
let generated = try await client.generate(.init(
  prompt: "투명 배경의 파란 새 한 마리",
  background: .transparent
))
// 사용자가 제공한 실제 PNG bytes를 전달합니다.
let input = ChatGPTImageContent(mimeType: "image/png", data: pngData, filename: "input.png")
let edited = try await client.edit(.init(images: [input], prompt: "새의 색만 초록색으로 바꾼다."))
```

`ChatGPTImageContent`가 request/result bytes를 소유합니다. Agent의 `ModelBinaryContent` 변환은 [Image adapter](../../../Agent/NativeAgentPackage/Packages/ChatGPTImageCapability/README.md)에만 있습니다. 파일·사진 권한·저장·artifact publication·승인·UI는 raw SDK 책임이 아닙니다.

공백 원문은 background 문장을 붙이기 전에 거부합니다. 크기/PNG 구조/입력 개수/출력 bytes의 한도는 `ChatGPTImageLimits`와 기존 public `ChatGPTImageClient` aliases가 소유합니다. 구조 검사는 이미지 의미·닮음·실제 alpha 조건의 성공 보증이 아닙니다.

구독 wire는 기존 `gpt-image-2`, `background=auto` pin을 유지하고 배경 의도는 prompt에 보존합니다. 이를 공개 OpenAI API와 동일한 서비스·과금·지원 계약으로 해석하지 않습니다. API key나 다른 model로 silent fallback하지 않습니다.

`ChatGPTImageFailure`는 안정적인 code/message와 선택적 HTTP status/request ID/제한된 code/reason만 반환합니다. 전체 오류 response body는 보존하지 않습니다. 403은 서비스 거부로 구분합니다. raw client가 반환하지 못한 remote effect는 Agent adapter에서 `outcomeUnknown`으로 처리할 수 있으며, 성공 여부가 불명확한 요청을 자동 재실행하지 않습니다.

[Agent Current](../../../Agent/NativeAgentPackage/docs/IMPLEMENTATION_STATUS.md) · [manifest](Package.swift) · [검증](../../../docs/verification/README.md). codec 검사는 실제 이미지 생성/편집 성공을 대체하지 않습니다.

## 독립 실행·완료

Image는 Account만 의존하며 Text/Agent/MCP를 요구하지 않는다. generate/edit의 HTTP 소비는 성공·오류·취소 모두 transport completion을 확인한다. drain 중 취소를 성공 반환하지 않는다. 원격 이미지 생성의 부재나 rollback을 보장하지 않으며 Agent adapter는 기존 outcomeUnknown 분류와 artifact publication 경계를 유지한다. custom transport에는 관리형 invocation 구현이 필요하다.


## 실패한 로컬 종료의 보존

`transportFailure` + `responseCode == "local_completion_unproved"`는 HTTP 요청의 로컬 종료를 증명하지 못했다는 뜻이다. client와 복사본들은 같은 quarantine를 공유하며 이미 실패한 모든 invocation을 보존한다. 새 generate/edit는 dispatch 전에 거절한다. 정상 종료가 증명된 parse/HTTP 오류에는 이 영구 차단을 적용하지 않는다.

이 결과를 자동 retry, 새 client 생성, 다른 모델/provider 선택으로 우회하지 않는다. host는 실패한 client를 유지하고 별도의 native 복구/프로세스 종료 정책으로 처리해야 한다. 이 원칙은 원격 효과의 존재·삭제·과금을 보증하지 않는다.


기존 subscription endpoint/profile을 보존했다. 원격 지원 범위와 생성 결과의 실제 alpha는 이번에 확인하지 않았다. `.transparent`는 요청 의도이며 결과의 투명도를 보장하지 않는다. [보존한 리서치와 qualification 제한](../../../docs/production/RESEARCH.md)을 확인한다.
