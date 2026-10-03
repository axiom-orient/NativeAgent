# 이미지 프롬프트 카탈로그

host가 명시 등록한 `ChatGPTImagesCapability`는 준비된 이미지 프롬프트를 조회하고 ChatGPTImage client로 실행한다. Text-only factory는 Image를 자동 설치하지 않는다. 원본 19개(참조 이미지 13개, 텍스트 생성 6개)와 예시 카테고리 보완용 12개를 제공한다. ASK 저장소·Sumday 일기 UI·계정 저장 방식에는 의존하지 않는다.

## 사용 흐름

1. `images.catalog.list`에서 프롬프트와 카테고리를 찾는다. 한국어 이름·설명과 영문 ID로 검색할 수 있다.
2. `images.catalog.read`에 `prompt_id` 또는 `category_id`를 전달한다. 설명·필수 변수·기본값·실패 기준과 스타일 예시 WebP artifact를 받는다.
3. `images.catalog.run`에 `prompt_id`, 조회한 `catalog_revision`, `variables`를 전달한다. 참조형은 기존 `images.edit`와 같은 `images` 입력 하나가 필수다. 텍스트형은 이미지 입력을 받지 않는다.

```json
{
  "prompt_id": "TO-01",
  "catalog_revision": "<조회 결과의 revision>",
  "variables": {"PLACE": "제주 성산일출봉", "TIME": "sunset"},
  "quality": "medium"
}
```

참조형 예: `IR-01`과 `images: [{"mime_type":"image/png", "artifact_relative_path":"<이 세션에서 반환된 정확한 경로>", "sha256":"<반환된 정확한 digest>"}]`. 실제 호출에는 예시 자리표시자를 넣지 않는다. 호스트가 제공한 PNG만 inline base64로 입력할 수 있다. WebP 예시를 사용자 원본으로 대체하지 않는다.

조회 도구는 read-only다. 실행 도구는 기존과 같이 approval을 요구하는 mutation이며 Agent kernel이 승인·effect·artifact·취소·복구를 소유한다. 동일 호출을 자동 반복하거나 생성 실패를 다른 과금 경로로 전환하지 않는다. default recipe는 host가 `ChatGPTImageSkills.installDefaultSkills`로 명시 설치한다. recipe의 selected 값과 이미지 capability 등록은 다른 concern이다.

실행 결과와 artifact metadata에 카탈로그 revision, prompt ID, 실제 prompt hash, 실패 기준이 남는다. 기존 PNG·크기·alpha 검사 결과는 그대로 유지하며 스타일·닮음·문자·개수 판정은 `semanticVerification=not_run`으로 명확히 구분한다. 후속 수정은 실제 생성 artifact를 `images.edit`에 전달하고 바꿀 한 가지와 보존할 조건을 다시 지정한다.

## 네이티브에서 사용

```swift
let catalog = try ChatGPTImagePromptCatalog.bundled()
let categories = catalog.categories
let previewURL = try catalog.previewURL(categoryID: "food-ukiyoe", thumbnail: true)
let brief = try catalog.prepare(
    promptID: "TO-01", variables: ["PLACE": "Jeju", "TIME": "sunset"]
)
// 기존 ChatGPTImageClient.generate(.init(prompt: brief)) 또는 Agent 도구로 실행.
// 변환은 prepare(..., referenceImageCount: 1) 후 실제 입력을 client.edit에 전달.
```

`previewURL`은 bundle 내부 WebP URL이다. ImageIO 또는 플랫폼 이미지 decoder로 표시하고 category.title·summary·previewNote는 이미지 밖의 네이티브 텍스트로 제공한다. 카드 안의 글자는 접근성 이름이나 카테고리 설명을 대신하지 않는다. 디코딩/I/O는 호스트가 UI 주 스레드 밖에서 수행하고 목록에서는 thumbnail을 사용한다. 저장·사진 선택·UI 상태·테마는 소비 앱이 소유한다. SDK가 Sumday에 새 화면을 자동 추가하지 않는다.

참조형에는 정확히 이미지 1장이 필요하다. 필수 변수 누락·빈 값·알 수 없는 키·지나치게 긴 값·오래된 revision은 provider 호출 전에 실패한다. 스티커는 1~16개와 쉼표로 구분한 같은 수의 표정, 마이크로스토리는 줄바꿈으로 구분한 3~8개 장면을 받는다. 원본의 범용 정책과 구체적인 변환 지시가 충돌하면 선택한 작업의 명시적인 변경 범위만 우선하고 나머지는 보존하도록 보완한다. 실제 보존 성공은 별도 결과 확인이 필요하다.

## 소스와 업데이트

- `PromptSources/universal/`: canonical Markdown prompt와 SHA256 checksum manifest. 메타데이터·설명·프롬프트 본문·실패 기준을 제공한다.
- `PromptSources/controls.json`: 필수 변수와 검토한 기본값. 원본의 “선택 변수” 목록 안에 있는 필수 콘텐츠도 여기서 강제한다.
- `PromptSources/extensions.json`: 원본 프롬프트와 구분되는 자체 작성 변환 12개. 실생성 품질은 미검증이다.
- `PromptSources/categories.json`: 예시와 프롬프트의 의미상 대응. 예시는 특정 ID·버전의 생성 성공 증거가 아니다. 블라인드 재조명(IR-10/TO-05)은 대응하는 예시가 없어 설명만 반환한다.
- `Sources/ChatGPTImageCapability/Resources/ImageCatalog/`: 생성된 JSON, 상세/목록 WebP, 이미지 해시·크기 manifest. SwiftPM에서 이 폴더 하나를 copy한다.

프롬프트 수정/추가 후 provider package 디렉터리에서 실행한다.

```sh
python3 Scripts/build_image_catalog.py
python3 Scripts/build_image_catalog.py --check
```

새 프롬프트는 고유하고 안정적인 ID를 사용하고 `controls.json`에 필수 변수·기본값을 함께 넣는다. 기존 ID의 의미를 바꿀 때 소비 앱의 저장된 선택을 고려한다. 카테고리를 추가하면 corresponding 예시 PNG와 카테고리 매핑을 함께 추가한다. 스크립트는 생성 결과가 오래됐거나 이미지가 누락/변조되면 실패한다.

이미지를 갱신할 때만 다음 명령을 사용한다. Python Pillow의 WebP encoder가 필요하며 앱 runtime dependency는 아니다.

```sh
python3 Scripts/build_image_catalog.py --cards-zip /absolute/path/category-example-cards.zip
```

원본을 자르거나 확대하지 않고 긴 변 960px/480px, 품질 84, method 6으로 변환한다. 원본 19장 6,186,228 bytes → 상세·목록 38장 합계 718,714 bytes(88.4% 감소). 중복 전체 contact sheet는 앱에 포함하지 않는다. 원본 ZIP은 수정하지 않는다. 카테고리 이미지 출처는 사용자 제공 ZIP이며 별도의 재배포 라이선스를 추정하지 않는다.

업데이트는 검토한 소스 변경 → 카탈로그 재생성 → 테스트 → 앱/SDK 배포 순서다. 자동 원격 다운로드는 없다. `validated(data:)`는 호스트가 보유한 snapshot 검증 API이며 기본 Agent 도구의 bundled catalog를 교체하지 않는다. 커스텀 snapshot용 외부 배포·서명·activation 정책은 현재 기능에 포함하지 않는다.

## 조사와 선택 근거 — 2026-09-14

[OpenAI 이미지 프롬프팅 가이드](https://developers.openai.com/api/docs/guides/image-prompting)는 주제·구도·스타일·제약을 구체화하고, 편집에서 변경과 보존을 구분하며, 참조의 역할을 명시하고 한 번에 한 가지를 수정하도록 안내한다. 카탈로그는 이를 변수 바인딩·참조 입력 강제·실패 기준·후속 편집 지침으로 적용한다. 프롬프트의 분량을 늘렸다는 이유로 품질 향상을 주장하지 않는다.

[OpenAI 이미지 생성 문서](https://developers.openai.com/api/docs/guides/image-generation)는 품질·출력 크기·압축 선택과 이미지 일관성/문자 표현의 한계를 설명한다. 이번 변경은 예시 파일만 WebP로 최적화한다. 구독 transport의 기존 PNG 검증 계약을 API 문서만 보고 바꾸지 않는다. 최신 API 모델 소개는 제3자 구독 endpoint의 해당 모델 지원 증거가 아니므로 기존 `gpt-image-2` pin을 유지한다.

[Codex 인증 문서](https://learn.chatgpt.com/docs/auth)는 ChatGPT 구독 인증과 API key 과금을 구분한다. 기존 client의 선택을 유지하며 이 문서를 제3자 iOS SDK endpoint의 공식 지원 보증으로 사용하지 않는다. 계정별 사용 가능 여부·한도·실제 생성 성공은 runtime qualification이 필요하다.

[Google WebP 문서](https://developers.google.com/speed/webp/docs/cwebp)는 크기와 압축 품질을 별도 제어하는 방식을 설명한다. [Apple ImageIO WebP](https://developer.apple.com/documentation/imageio/webp-data)와 실제 native decode 검사를 사용해 외부 decoder dependency 없이 번들 미리보기를 제공한다.

여러 개의 긴 스킬을 기본 선택하는 방식은 발견 지침·업데이트 대상이 늘어난다. 이번에는 한 데이터 카탈로그와 3개 도구로 기존 스킬과 공존하도록 구성했다. 명시적인 모델 호출 전 필수 입력을 검증하고 특정 프롬프트만 조회하므로 비용과 지침 충돌을 줄일 수 있는 구조다. 실제 토큰·생성 지연 개선량은 측정하지 않았다.

다음 품질 변경은 동일한 실제 입력·설정에서 기존/새 prompt revision을 비교하여 판단한다. 스타일별 실패 기준을 확인하며 모의 client 테스트는 routing·validation 증거로만 사용한다. 특히 예시 음식 목판화의 서예, 여행 포스터의 제목, 즉석필름의 프레임은 기본 프롬프트가 자동 복제하지 않는다.

## 검증 범위와 현재 상태

현재 source의 catalog 변수 검증·generator 정합성·실환경 미검증은 [Agent Current](../../docs/IMPLEMENTATION_STATUS.md)와 [Current](../../docs/IMPLEMENTATION_STATUS.md)가 소유한다. 기존 문서의 과거 macOS/iOS·ImageIO PASS는 첨부에 대응 로그가 없어 이번 결과로 승계하지 않았다. runtime 입력·생성물·preview 업데이트 절차와 원래 모델/계정 pin은 유지한다.

`validated(data:)`와 `prepare`는 기본값과 병합된 입력 값의 빈 문자열/공백·문자 수 상한을 같은 규칙으로 검사한다. 공개 Codable decode 경로 뒤에 prepare를 호출해도 기본값 검사가 적용된다. 변수 치환은 값 안의 placeholder를 다시 재귀 치환하지 않는다. 실제 이미지 의미/스타일 품질의 검증은 별도다.
