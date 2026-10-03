---
id: IR-03
mode: REFERENCE_IMAGE_REQUIRED
category: character-transform
---

# 사진 → 손그림·종이 콜라주 어린이 만화 캐릭터

## 목적

사진 속 인물을 손으로 오리고 그린 듯한 어린이 책·콜라주 만화 미감으로 변환한다.

## 입력

- 필수: 인물/캐릭터 이미지 1장
- 선택: 배경 보존, 종이 질감 강도

## 범용 프롬프트

```text
Transform the subject in the uploaded image into a playful hand-drawn children's storybook character made from loose ink lines, flat paper-like color shapes, and imperfect cut-paper collage textures.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

IDENTITY:
- Preserve the subject's recognizable face, hairstyle, outfit colors, pose, expression, and major proportions.
- Simplify details into childlike graphic shapes without making the subject unrecognizable.

STYLE:
- Use irregular pencil/ink contours, flat matte colors, visible paper texture, naive handmade cut edges, and sparse collage marks.
- Keep the result intentionally imperfect and tactile rather than glossy, vector-clean, or 3D.
- Default background: simple off-white paper with only minimal shapes needed to support the original scene.

Avoid imitating any named television/book franchise, exact proprietary character design, photoreal rendering, anime, polished 3D, or excessive decoration.
```

## 선택 변수

- `BACKGROUND_MODE` — paper / preserve / simple-custom
- `PAPER_TEXTURE` — light / medium / strong

## 실패 기준

- 특정 프랜차이즈 캐릭터를 그대로 모사함
- 인물 식별성이 사라짐
- 3D/벡터처럼 지나치게 매끈함
- 원본 포즈·의상이 불필요하게 변경됨
