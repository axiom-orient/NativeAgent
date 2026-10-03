---
id: IR-10
mode: REFERENCE_IMAGE_REQUIRED
category: portrait-relighting
---

# 인물 사진 → 블라인드 그림자 드라마틱 초상

## 목적

인물 정체성을 유지한 채 수평 블라인드 그림자를 이용한 강한 명암의 초상으로 재조명한다.

## 입력

- 필수: 인물 사진 1장
- 선택: 그림자 방향, 대비 강도, 색감

## 범용 프롬프트

```text
Relight the uploaded portrait with dramatic sunlight passing through horizontal window blinds.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

PORTRAIT LOCK:
- Preserve the person's real facial structure, eye color, skin tone, age cues, hair, expression, and body geometry.
- Do not alter eye color or facial proportions for impact.

LIGHTING:
- Cast physically coherent horizontal bands of warm directional light and crisp-to-soft shadow across the face and visible body.
- Keep catchlights, shadow direction, and exposure consistent with one believable light source.
- Use strong but controlled contrast; retain detail in both lit and shadowed areas.
- Apply only minimal skin cleanup; preserve pores and natural texture.

Avoid glamour retouching, glowing skin, artificial eye enhancement, new makeup, face reshaping, or added props.
```

## 선택 변수

- `SHADOW_DIRECTION` — left-to-right / right-to-left / custom
- `CONTRAST` — medium / strong
- `TONE` — neutral / warm / moody

## 실패 기준

- 눈색/얼굴형 변경
- 블라인드 그림자 방향이 물리적으로 불일치
- 과도한 피부 보정
- 원본 포즈/크롭 변경
