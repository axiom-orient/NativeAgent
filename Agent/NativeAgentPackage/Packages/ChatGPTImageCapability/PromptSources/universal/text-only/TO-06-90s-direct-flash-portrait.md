---
id: TO-06
mode: TEXT_ONLY
category: portrait-generation
---

# 텍스트 → 1990년대 직접 플래시 필름 초상

## 목적

1990년대 스냅 사진의 직접 플래시·그레인·고대비 특성을 텍스트만으로 생성한다.

## 입력

- 필수: SUBJECT_DESCRIPTION
- 선택: LOCATION, COLOR_BIAS, FRAMING

## 범용 프롬프트

```text
Create a nostalgic 1990s film-photography portrait of `SUBJECT_DESCRIPTION` using harsh direct on-camera flash.

GENERATION DISCIPLINE:
- Build only from the supplied variables and description.
- Keep subject, setting, composition, medium, lighting, palette, and output treatment internally consistent.
- Do not add text, logos, watermarks, extra subjects, or decorative objects unless explicitly requested.
- Prefer a clear focal hierarchy over unnecessary detail.

- Use bright frontal flash on the subject, fast light falloff, darker ambient background, crisp local contrast, and subtle hard-edged flash shadows where physically plausible.
- Add fine irregular film grain, slightly imperfect color, mild print softness, and restrained highlight bloom.
- Keep the scene candid and minimally styled.
- Use `LOCATION` only as a simple contextual background and keep the subject dominant.

Avoid modern HDR, cinematic rim lights, fake light leaks, VHS artifacts, heavy scratches, beauty retouching, text, and logos.
```

## 선택 변수

- `SUBJECT_DESCRIPTION` — person, clothing, expression
- `LOCATION` — party / room / street / custom
- `COLOR_BIAS` — neutral / warm / cool
- `FRAMING` — close-up / waist-up / full-body

## 실패 기준

- 플래시 외 다른 주광원이 난립
- VHS/캠코더 스타일로 변질
- 과도한 필름 손상
- 현대적 HDR/뷰티 룩
