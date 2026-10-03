---
id: TO-05
mode: TEXT_ONLY
category: portrait-generation
---

# 텍스트 → 골든아워 블라인드 그림자 초상

## 목적

사진 없이도 수평 블라인드 그림자의 골든아워 초상을 일관되게 생성한다.

## 입력

- 필수: SUBJECT_DESCRIPTION
- 선택: FRAMING, BACKGROUND, MOOD

## 범용 프롬프트

```text
Create a cinematic portrait of `SUBJECT_DESCRIPTION` lit by warm golden-hour sunlight passing through horizontal window blinds.

GENERATION DISCIPLINE:
- Build only from the supplied variables and description.
- Keep subject, setting, composition, medium, lighting, palette, and output treatment internally consistent.
- Do not add text, logos, watermarks, extra subjects, or decorative objects unless explicitly requested.
- Prefer a clear focal hierarchy over unnecessary detail.

- Cast distinct horizontal bands of warm light and shadow across the face and visible upper body.
- Keep all shadow bands consistent with a single window/light direction and believable facial geometry.
- Use restrained warm color, deep but detailed shadows, realistic skin texture, and subtle lens softness.
- Compose with `FRAMING` and a simple environment described by `BACKGROUND`.
- Maintain natural anatomy and avoid beauty-editorial exaggeration unless explicitly requested.

No text, logos, unnecessary props, fantasy light sources, or glowing eyes.
```

## 선택 변수

- `SUBJECT_DESCRIPTION` — appearance, clothing, pose
- `FRAMING` — close-up / head-and-shoulders / half-body
- `BACKGROUND` — simple interior description
- `MOOD` — quiet / somber / warm / introspective

## 실패 기준

- 그림자 줄 방향/광원이 모순
- 피부가 플라스틱처럼 과보정
- 불필요한 렌즈 플레어/광원 추가
- 장면보다 효과가 과함
