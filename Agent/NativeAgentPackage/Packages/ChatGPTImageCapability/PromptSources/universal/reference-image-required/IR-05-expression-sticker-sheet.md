---
id: IR-05
mode: REFERENCE_IMAGE_REQUIRED
category: sticker-sheet
---

# 사진/캐릭터 → 범용 메신저 스티커 시트

## 목적

한 인물/캐릭터의 정체성을 유지하면서 다양한 표정의 메신저 스티커 세트를 만든다.

## 입력

- 필수: 기준 이미지 1장
- 선택: 스티커 수, 표정 목록, 배경/테두리

## 범용 프롬프트

```text
Create a cohesive messaging-app sticker sheet from the uploaded subject.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

CONSISTENCY:
- Preserve the same identity, hairstyle, outfit, key accessories, color palette, and character proportions across every sticker.
- Vary expression and small gesture only; do not generate different-looking versions of the subject.

STICKER DESIGN:
- Use clean readable silhouettes, simplified detail, expressive face and hands, compact compositions, and consistent rendering.
- Default to transparent or plain background with an optional clean sticker cutline.
- Arrange exactly `STICKER_COUNT` distinct stickers in a regular grid with no overlap.

EXPRESSIONS:
Use the supplied `EXPRESSIONS`. If omitted, use a balanced set such as joy, laugh, surprise, confusion, embarrassment, sadness, anger, determination, sleepiness, celebration, thanks, apology, thinking, approval, refusal, and love.

Do not add captions unless exact text is explicitly provided.
```

## 선택 변수

- `STICKER_COUNT` — default 16
- `EXPRESSIONS` — comma-separated list
- `CUTLINE` — none / thin / bold
- `BACKGROUND` — transparent / white / custom

## 실패 기준

- 스티커마다 다른 사람/캐릭터가 됨
- 요청 개수 불일치
- 표정 차이가 불명확함
- 임의 텍스트/워터마크가 생김
