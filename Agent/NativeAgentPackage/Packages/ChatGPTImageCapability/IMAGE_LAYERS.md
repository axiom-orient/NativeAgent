# 이미지 레이어 API와 실행 계약

상태: **PARTIAL / [UNVERIFIED]**. 이 문서는 이번에 작성한 코드의 계약이다. 빌드, 테스트, 실제 provider 호출, 픽셀 비교를 실행한 결과가 아니다.

## 1. 제품 범위

`ChatGPTImageCapability`의 기존 이미지 capability를 확장한다. 별도 Agent, 별도 실행 원장, 별도 저장소, UI 또는 독립 segmentation 모델을 추가하지 않는다.

현재 경로:

```text
실제 원본 PNG
  → Agent/host가 제안한 의미 레이어 목록
  → prepare / images.layers.plan
  → 원본 digest + 동일 canvas + 뒤→앞 순서가 고정된 Plan
  → 승인된 images.layers.render, 레이어마다 한 번
  → 실제 alpha PNG 후보
  → PNG/크기/색공간/최소 alpha 조건 검사
  → 결정론적 chroma export
  → kernel이 chroma PNG + alpha-source artifact 저장
  → 사람의 의미·형태·원본 충실도 검토
  → alpha source들로 recompose
```

**자동 의미 분할 모델이나 원본 pixel ownership mask는 구현되지 않았다.** 레이어 목록은 Agent/host의 제안이다. `render`는 기존 edit provider에 한 요소를 분리하도록 요청한다. 원본의 가시 픽셀을 직접 잘라 복사하는 mask 기반 추출기가 아니다. 따라서 좋은 결과가 나올 수 있다는 설계 의도와 정확한 원본 보존을 입증한 구현을 구분해야 한다.

이 작업에는 분리할 원본 이미지가 첨부되지 않았다. 카탈로그 예시 WebP는 원본 대신 사용할 수 없다.

## 2. 하나의 진입점과 상태

공개 진입점은 기존 product 안의 `ChatGPTImageLayers` 값이다.

| API | 역할 | 외부 효과 |
| --- | --- | --- |
| `prepare(source:layers:)` | 실제 PNG를 읽고 원본 hash·canvas·레이어 순서를 고정 | 없음 |
| `render(plan:layerID:source:turnID:)` | 정확히 한 레이어의 edit 요청과 후보 처리 | 기존 `ChatGPTImageServing.edit` 한 번 |
| `recompose(plan:layers:)` | 현재 프로세스에서 받은 후보 재합성 | 없음 |
| `recompose(plan:sources:)` | 저장된 alpha-source를 읽어 온 host의 재합성 | 없음 |

`Outcome`은 `candidate(RenderedLayer)` 또는 `rejected(RejectedCandidate)`다. provider 응답 자체와 의미적으로 승인된 최종 결과를 같은 상태로 표현하지 않는다. 공개 `verified layer` 상태도 만들지 않는다.

`RenderedLayer.source`의 압축 PNG가 **유일한 재합성 정본**이다. `chromaImage`는 export/projection이다. 작업용 premultiplied RGBA 배열은 내부 지역 값이며 공개 상태에 중복 저장하지 않는다.

## 3. 원본·계획 계약

원본은 명시적으로 다음을 만족해야 한다.

- 실제 정적 PNG, orientation 1, 8-bit RGB/RGBA, ImageIO가 인식한 명시적 sRGB.
- 원본 바이트는 모델 요청에 그대로 전달한다. crop, resize, recenter, 임의 회전은 하지 않는다.
- JPEG/HEIC/WebP, P3, 16-bit 또는 다른 색공간을 layer 작업에서 몰래 sRGB로 바꾸지 않는다. host의 명시적 정규화가 필요하다. 정규화한 경우 그 결과가 새 작업 원본이며, 정규화 전 이미지와 무손실 동등하다고 주장할 수 없다.
- 명시적인 sRGB profile의 이름 판정은 엄격하다. 동등하지만 다른 이름으로 인식된 profile의 허용 범위를 넓히지 않았다.

`Plan`은 `schemaVersion = 1`, `sourceSHA256`, `width`, `height`, `layers`를 가진다. `Plan.layers`만 z-order의 주인이다. 배열 순서는 **뒤→앞**이다.

레이어 수는 1...64다. ID는 1...64 UTF-8 bytes의 ASCII 영문자·숫자·`-`·`_`이며 중복을 허용하지 않는다. subject와 복원 설명은 각각 1...2000 UTF-8 bytes, 공백 전용/NUL 불가다. background는 선택적이며 최대 하나, 반드시 첫 번째다.

가려진 부분의 요청은 `Occlusion.none`과 `Occlusion.restore(description:)`로 구분한다. 복원된 부분은 관측된 사실이 아니라 추론된 후보다. `Layer`와 `Plan`의 `Decodable` 초기화도 검사를 통과해야 한다.

`Plan.encoded()`는 정렬된 JSON을 출력하며 최대 384 KiB다. `Plan.digest()`는 이 canonical encoding의 SHA-256이다. 도구의 `plan_sha256`에는 kernel이 실제 저장 artifact에 반환한 **contentSHA256**을 전달한다. `images.layers.plan`이 출력한 canonical bytes에서는 두 값이 같지만, 외부 JSON을 다시 직렬화한 뒤 기존 artifact hash를 재사용하면 안 된다.

## 4. 크로마키와 재합성

외부 모델에는 크로마키가 아닌 **실제 alpha PNG**를 요청한다. 프로그램은 해독한 alpha를 사용해 export 배경을 만든다.

후보 키는 두 개뿐이다.

```text
green   = (0, 177, 64)  = #00B140
magenta = (255, 0, 255) = #FF00FF
```

선택은 A > 0인 subject 표본들의 unassociated RGB와 각 후보의 최소 제곱 RGB 거리 중 큰 값을 택한다. 동률은 green이다. 이는 명시적인 sample-space metric이며 지각적으로 최적이라는 뜻이 아니다. 두 키 모두 subject에 등장해 점수가 0이면 `chromaOnlyCollision = true`를 기록한다.

8-bit premultiplied component `C`, alpha `A`, key component `K`에 대해 export는 다음 정수식을 사용한다.

```text
C_export = C + floor((K * (255 - A) + 127) / 255)
A_export = 255
```

A = 0인 픽셀은 **정확히 key 단일색**이 된다. A = 255인 subject 픽셀은 그대로다. 부분 alpha는 색 번짐 제거, threshold, 모양 변경 없이 key 위에 합성한다. 모델이 잘못 남긴 A > 0 잔상은 이 식만으로 대상 외부라고 판별할 수 없다. 그러므로 “투명 영역의 단색 처리”와 “의미상 대상 외 모든 영역의 정확한 분리”를 혼동하면 안 된다.

재합성은 chroma key를 추측해 제거하지 않는다. 저장한 alpha PNG를 해독하고 plan 순서대로 source-over한다. 픽셀식은 premultiplied sRGB **sample-space**에서 각 RGBA component에 동일한 반올림을 사용한다.

```text
C_out = C_front + floor((C_back * (255 - A_front) + 127) / 255)
A_out = A_front + floor((A_back * (255 - A_front) + 127) / 255)
```

이는 선형광 합성이나 원본과의 무손실 일치를 보장하는 계약이 아니다. 반투명 채널의 8-bit premultiplication/encoding 반올림도 원본 alpha PNG 자체의 보존과 구분한다. PNG 파일 인코더 출력 바이트의 OS 간 동일성도 보장하지 않는다. 결정론적 계약은 순수 계획·선택·픽셀 계산에 적용한다.

## 5. 도구와 저장 경계

기존 다섯 도구 `images.generate`, `images.edit`, `images.catalog.list`, `images.catalog.read`, `images.catalog.run`을 유지하고 다음 두 개만 추가한다.

`images.layers.plan`: `image`, `layers[{id, subject, role, restore_hidden?}]`. 원격 요청 없는 read-only 도구이며 automatic 정책이다. 계획 artifact 쓰기는 다른 결과 artifact와 마찬가지로 kernel 책임이다.

`images.layers.render`: `plan_artifact_relative_path`, `plan_sha256`, `image`, `layer_id`. mutation이며 requireApproval이다. 호출마다 한 레이어만 생성한다. 접촉시트, 숨은 batch, 병렬 task, 자체 재시도는 없다.

정상 후보 artifact:

```text
<layerID>.png          image/png                 사람이 보는 chroma image 1장
<layerID>.rgba-source  application/octet-stream  원래 alpha PNG bytes, display=false
```

`.rgba-source`는 독자적인 이미지 포맷이 아니다. 내용은 provider가 반환한 PNG bytes이며, 기본 UI에서 두 번째 이미지로 노출하지 않도록 확장자/MIME를 구분했다. metadata의 `rgbaSourceEncoding`, `rgbaSourceSHA256`으로 읽는다. host UI가 별도 display metadata를 무시하는 경우의 화면 동작은 미검증이다.

후보에는 layer ID, source/plan hash, canvas, stack index, chroma key/거리, provider request ID/turn ID를 기록한다. 실제 로컬 검사를 통과한 후보만 `contractVerification=verified`로 표시하며 범위는 `source_binding`, `plan_binding`, `canvas`, `alpha_admission`, `chroma_projection`, `stack_index`다. 이는 source digest 일치, immutable plan digest, 동일 canvas, 최소 alpha 조건, 실제 RGBA→chroma projection, plan 내 stack 위치를 코드가 직접 확인했다는 뜻이다. `semanticVerification=not_run`, `recompositionVerification=not_run`, `status=candidate_review_required`는 그대로 유지한다.

`CandidateContractVerification`은 외부 public initializer가 없고 admitted candidate 생성 경로에서만 만들어진다. 따라서 단순 metadata 문자열만으로 verified 상태를 만들 수 없다. 반대로 의미 분할 정확도, 원본 시각 충실도, occlusion 복원 정확도는 이 타입의 범위가 아니며 verified로 승격하지 않는다.

부적합한 bounded 응답은 `<layerID>.rejected-source` 하나로 보존하며 image MIME로 가장하지 않는다. 내용과 거부 사유를 유지하고 `isError=true`로 반환한다. 도구는 파일을 직접 저장하지 않는다. `ToolResult.artifacts`의 `ArtifactWriteRequest`만 반환한다.

참조 입력은 기존 descriptor-relative resolver를 공유한다. 현재 session 아래 `sessions/<id>/artifacts/...`만 허용하고 exact hash를 요구한다. `..`, 절대경로, 빈 경로 요소, symlink, FIFO/비정규 파일, 크기 초과, hash 불일치를 허용하지 않는다. plan은 동일 resolver에 384 KiB 상한을 적용한다.

## 6. 효과·취소·권한

host 직접 API는 승인 시스템이 아니다. 직접 `render`를 호출하는 host가 승인과 operation identity를 소유한다. Agent 도구 경로에서는 기존 kernel이 승인·effect ledger·artifact 저장·복구를 소유한다.

| 관측 상태 | 처리 |
| --- | --- |
| 입력 불일치, dispatch 이전 취소 | `EffectFailure.definiteFailure` |
| provider가 invalidRequest/authenticationRequired/rateLimited를 반환 | definiteFailure |
| provider가 HTTP 400/401/403/413/422/429를 명시적으로 반환 | code와 무관하게 definiteFailure; 403은 serviceRejected로 표시 |
| serviceRejected/malformedResponse/limitExceeded/cancelled/transportFailure에 명시 상태가 없음 | outcomeUnknown |
| provider가 bounded bytes를 반환했으나 layer 조건 불충족 | bytes를 보존하는 `rejected` 결과, 자동 재시도 없음 |
| provider 반환 후 empty/oversize 또는 결과 발행 실패 | outcomeUnknown, 원격 효과가 없었다고 주장하지 않음 |
| provider 반환과 함께 cancellation 관측 | 반환된 결과를 kernel이 저장할 수 있도록 반환, 뒤늦게 버리지 않음 |

`turnID`는 직접 API에서 host가 주입한다. 도구 adapter는 dispatch에 사용할 UUID를 만든다. server request ID나 turn UUID를 원격 exactly-once key로 해석하지 않는다. 중복 호출·재개 정책은 기존 tool-call identity와 effect ledger가 소유한다. 새로운 ledger/state machine을 추가하지 않았다.

`ChatGPTImageFailure`의 진단은 bounded HTTP status, request ID, response code/reason만 포함한다. 전체 provider response body는 effect record나 오류에 보존하지 않으며, 400/422의 reason은 prompt 또는 요청 본문이 다시 노출되지 않도록 생략한다.

`ChatGPTImageLayers`, Plan, 결과는 `Sendable` 값이다. actor는 production에 추가하지 않았다. 숨은 detached Task, MainActor, UI 의존성도 없다. `prepare`/`recompose`는 동기 CPU 작업이므로 실행할 executor와 task 수는 host가 선택한다.

## 7. 실제 API 사용 예제 — 실행하지 않음

아래 함수는 host가 승인한 호출에 한해 사용한다. `layers`는 실제 원본을 분석해 만든 설명이다. 예시용 이미지/임의 subject를 자동으로 끼워 넣지 않는다.

```swift
import Foundation
import LanguageModelCore
import ChatGPTImageCapability

func renderOneApprovedLayer(
  client: any ChatGPTImageServing,
  originalPNG: Data,
  layers: [ChatGPTImageLayers.Layer],
  layerID: String,
  turnID: UUID
) async throws -> (ChatGPTImageLayers.Plan, ChatGPTImageLayers.Outcome) {
  let api = ChatGPTImageLayers(client: client)
  let source = ModelBinaryContent(
    mimeType: "image/png", data: originalPNG, filename: "source.png")
  let plan = try api.prepare(source: source, layers: layers)
  let outcome = try await api.render(
    plan: plan, layerID: layerID, source: source, turnID: turnID)
  return (plan, outcome)
}
```

반환값은 `switch`로 처리한다. `.candidate`는 사용자 검토 대상으로 발행하고 `.rejected`의 bytes·reason을 보존한다. source와 plan을 수정하지 않고 다른 layer ID를 호출한다. 모든 layer가 모이기 전에는 재합성이 성공한 것으로 표시하지 않는다.

저장 후 재시작한 host는 alpha artifact bytes와 **host 소유 metadata**를 읽어 다음 값을 만든다. 해당 파일의 bytes와 hash를 동시에 임의로 바꾼 입력에 대해 SHA-256이 진본성을 보증하는 것은 아니다.

```swift
func restoreRecompositionSource(
  layerID: String,
  planSHA256: String,
  alphaPNG: Data,
  artifactSHA256: String
) throws -> ChatGPTImageLayers.RecompositionSource {
  try .init(layerID: layerID, planSHA256: planSHA256,
    png: alphaPNG, contentSHA256: artifactSHA256)
}

func recomposeStoredLayers(
  client: any ChatGPTImageServing,
  plan: ChatGPTImageLayers.Plan,
  sources: [ChatGPTImageLayers.RecompositionSource]
) throws -> ChatGPTImageLayers.VerifiedRecomposition {
  try ChatGPTImageLayers(client: client).recomposeVerified(plan: plan, sources: sources)
}
```

파일 읽기·쓰기·승인·artifact 원장은 위 API 밖이다. 재합성 호출은 주입한 client를 사용하지 않는다. 이미지 생성 client를 fake로 교체해야만 재합성이 가능한 설계는 아니다; 기존 facade instance/client를 그대로 쓴다.

## 8. 한도와 남은 조건

원본 input 50 MiB, provider/output PNG 32 MiB, working raster 16,777,216 pixels 및 RGBA8 64 MiB 상한을 기존 provider 상수와 공유한다. ImageIO decode cache·입출력 배열·임시 복사까지 포함한 process peak memory가 64 MiB라는 뜻은 아니다. 최대 크기·여러 레이어의 Apple 실기기 메모리 동작은 미측정이다. kernel의 기존 artifact/session quota도 별도로 적용된다.

공개 PNG framing 검사기는 signature, critical chunk 구조, CRC, palette/transparency 일부 제약, IDAT/IEND, bounds를 검사하고 실제 codec은 ImageIO를 사용한다. 전체 PNG 표준 적합성 구현이나 독립 보안 인증을 의미하지 않는다. 기존 일반 생성 결과의 16-bit alpha는 `unknown`/`structural_only`로 남으며, 신규 layer 경로는 16-bit를 거부한다.

현재 코드로 검증 완료된 범위는 source/plan digest binding, plan canvas, element/background alpha admission, RGBA→chroma projection identity, immutable plan의 back-to-front recomposition order와 output digest다. 재합성의 `planSourceSHA256`은 plan에 선언된 source identity이며 persisted layer provenance를 독립적으로 재증명하는 값은 아니다.

필수 잔여 작업은 실제 원본·provider를 사용한 의미 분할 및 원본 충실도 평가, 원본 visible-pixel ownership/matte 계약, 복원 영역 provenance, host의 개별 이미지 표시, kernel durable transaction과 cancellation 통합 실행이다. 이 의미/시각 검증은 이번 작업에서 수행하지 않았다.

## 참고 근거

- [W3C PNG Third Edition](https://www.w3.org/TR/png-3/): PNG alpha는 unassociated이며 row/chunk/CRC가 별도 계약이다. 크로마키를 alpha 정본 대신 사용하지 않는 설계의 근거다.
- [Apple TN2313](https://developer.apple.com/library/archive/technotes/tn2313/_index.html): 색값은 profile과 함께 의미가 있으며 색공간 변환은 손실을 만들 수 있다. 오래된 기본 원리 참고자료로 사용했으며 최신 OS 지원 증거로 사용하지 않았다.
- [Apple ImageIO](https://developer.apple.com/documentation/imageio): codec은 시스템 구현을 사용한다. API 문서의 JS/Markdown 제공 상태로 세부 본문 일부를 가져오지 못했으며, SDK compile/runtime 검증을 대신하지 않는다.
