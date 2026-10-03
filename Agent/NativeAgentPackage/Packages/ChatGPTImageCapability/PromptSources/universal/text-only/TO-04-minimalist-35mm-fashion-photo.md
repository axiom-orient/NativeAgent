---
id: TO-04
mode: TEXT_ONLY
category: photo-generation
---

# 텍스트 → 미니멀 35mm 패션 사진

## 목적

피사체 설명만으로 필름 질감이 분명한 미니멀 패션 사진을 만든다.

## 입력

- 필수: SUBJECT_DESCRIPTION
- 선택: LOCATION, WARDROBE, LENS_FEEL, PALETTE

## 범용 프롬프트

```text
Create a refined minimalist fashion photograph on 35mm film featuring `SUBJECT_DESCRIPTION`.

GENERATION DISCIPLINE:
- Build only from the supplied variables and description.
- Keep subject, setting, composition, medium, lighting, palette, and output treatment internally consistent.
- Do not add text, logos, watermarks, extra subjects, or decorative objects unless explicitly requested.
- Prefer a clear focal hierarchy over unnecessary detail.

- Use clean composition, deliberate negative space, understated wardrobe and environment, and one clear focal gesture.
- Render prominent but fine organic film grain, natural highlight roll-off, gentle halation, slightly compressed contrast, and plausible analog color response.
- Keep lighting simple and physically motivated.
- Preserve realistic anatomy, fabric behavior, and lens perspective.
- No logos, captions, fake date stamps, or excessive editorial props.

The image should feel like a real photographed frame, not a digital image with a grain overlay.
```

## 선택 변수

- `SUBJECT_DESCRIPTION` — person/object and pose
- `LOCATION` — studio / street / interior / custom
- `WARDROBE` — optional
- `LENS_FEEL` — 28mm / 35mm / 50mm / 85mm-like
- `PALETTE` — neutral / warm / cool

## 실패 기준

- 필름 질감이 디지털 오버레이처럼 균일함
- 패션보다 소품/배경이 우세
- 과도한 뷰티 리터칭
- 비현실적 해부학/렌즈 왜곡
