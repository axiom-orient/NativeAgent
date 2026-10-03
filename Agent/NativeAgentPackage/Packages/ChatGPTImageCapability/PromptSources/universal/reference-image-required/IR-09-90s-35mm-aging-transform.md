---
id: IR-09
mode: REFERENCE_IMAGE_REQUIRED
category: photo-filter
---

# 사진 → 1990년대 35mm 필름 에이징

## 목적

기존 사진을 과도한 필터 없이 1990년대 소비자용 35mm 필름 느낌으로 에이징한다.

## 입력

- 필수: 사진 1장
- 선택: 색온도, 그레인 강도, 플래시 흔적

## 범용 프롬프트

```text
Age the uploaded image as a plausible 1990s consumer 35mm film photograph.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

FILM RESPONSE:
- Add fine irregular grain, slightly faded color, milky lifted blacks, moderate contrast compression, gentle highlight halation, and small color shifts typical of aging print film.
- Preserve realistic skin, materials, and local contrast.
- Keep the effect uneven and organic rather than a uniform digital overlay.
- Optional direct-flash character may be added only when `FLASH=yes`, without changing the existing lighting geometry drastically.

Avoid heavy VHS artifacts, fake light leaks across the subject, extreme cyan/orange grading, scratched-film damage, or composition changes.
```

## 선택 변수

- `GRAIN` — fine / medium
- `COLOR_BIAS` — neutral / warm / cool
- `FLASH` — yes / no

## 실패 기준

- 필터가 장면보다 강함
- VHS/비디오 느낌으로 변질
- 얼굴/피사체 보정 또는 재생성
- 빛샘·스크래치 남용
