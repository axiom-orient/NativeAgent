---
id: IR-13
mode: REFERENCE_IMAGE_REQUIRED
category: travel-collage
---

# 사진 → 여행 마이크로스토리 콜라주

## 목적

한 피사체를 기준으로 여러 여행 순간을 각각 독립된 작은 장면으로 구성한다.

## 입력

- 필수: 주 피사체 이미지 1장
- 필수: 마이크로스토리 목록 3~8개
- 선택: 콜라주 재질/팔레트

## 범용 프롬프트

```text
Use the uploaded main subject to create a coherent travel collage made of multiple distinct micro-story scenes.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

- Preserve the subject's identity and core appearance consistently wherever the subject appears.
- Create exactly one vignette for each item in `MICRO_STORIES`, with clearly different setting/action while retaining the same traveler identity.
- Organize vignettes as a balanced scrapbook/postcard composition with clean visual separation, consistent paper/print treatment, and one shared palette.
- Keep each vignette readable at thumbnail size.
- Add no destination, event, caption, date, or icon that was not supplied.
- No pseudo-text.

If the source image does not show enough detail for a requested full-body/action scene, preserve identity conservatively and avoid inventing distinctive clothing details.
```

## 선택 변수

- `MICRO_STORIES` — ordered list of scenes
- `LAYOUT` — grid / organic collage / strips
- `STYLE` — paper collage / illustrated postcard / mixed print

## 실패 기준

- 장면 수 불일치
- 장면마다 인물 정체성 변경
- 사용자 미제공 사건/목적지 추가
- 작은 장면들이 서로 합쳐져 의미가 불명확함
