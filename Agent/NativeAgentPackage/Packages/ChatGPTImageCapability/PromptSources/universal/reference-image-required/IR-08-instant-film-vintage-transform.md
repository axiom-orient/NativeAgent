---
id: IR-08
mode: REFERENCE_IMAGE_REQUIRED
category: photo-filter
---

# 사진 → 빈티지 즉석필름 사진

## 목적

원본 인물과 장면을 보존한 채 자연스러운 빈티지 즉석필름 사진 특성만 적용한다.

## 입력

- 필수: 사진 1장
- 선택: 필름 연대감, 프레임 유무, 흐림 강도

## 범용 프롬프트

```text
Transform the uploaded photo into a natural vintage instant-film photograph.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

- Keep real facial identity, anatomy, expression, clothing, pose, and scene content unchanged.
- Apply gentle optical softness, fine-to-medium analog grain, slightly lowered contrast, warm-to-neutral faded color, soft highlight roll-off, mild shadow lift, and subtle chemical-print irregularity.
- Keep skin natural; do not smooth or beautify it.
- Add a classic instant-print border only when `FRAME=yes`; otherwise keep the original crop.

Avoid fake dust storms, heavy scratches, orange filters, excessive blur, face retouching, composition changes, or pseudo-date stamps.
```

## 선택 변수

- `ERA_FEEL` — 70s / 80s / 90s / timeless
- `FRAME` — yes / no
- `SOFTNESS` — low / medium

## 실패 기준

- 얼굴이 변경/보정됨
- 필름 효과가 과해 디테일이 무너짐
- 원본 크롭/구도가 바뀜
- 프레임/날짜가 임의 추가됨
