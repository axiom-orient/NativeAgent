---
id: IR-02
mode: REFERENCE_IMAGE_REQUIRED
category: character-transform
---

# 사진 → 세련된 3D 애니메이션 캐릭터 초상

## 목적

인물의 정체성·헤어·표정·의상을 보존한 채 브랜드 비의존적인 고품질 3D 애니메이션 캐릭터로 변환한다.

## 입력

- 필수: 인물 사진 1장
- 선택: 배경, 귀여움 강도, 재질 단순화 정도

## 범용 프롬프트

```text
Transform the uploaded person into a polished, friendly 3D animated character portrait with a premium family-animation look.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

IDENTITY FIDELITY:
- Preserve recognizable facial structure, skin tone, hairstyle, expression, age cues, eyewear, outfit, and distinctive features.
- Stylize proportions gently; do not replace the person with a generic character archetype.

RENDERING:
- Use clean rounded forms, soft physically plausible shading, expressive but proportional eyes, simplified materials, and tidy silhouette design.
- Keep skin texture smooth but not plastic; preserve natural asymmetry that supports likeness.
- Use clean studio-quality lighting without dramatic relighting unless requested.

BACKGROUND:
- Default to a plain neutral studio background. Preserve the original environment only when `BACKGROUND_MODE=preserve`.

Avoid brand-specific character design, exaggerated baby proportions, face replacement, costume redesign, extra accessories, text, logos, and watermarks.
```

## 선택 변수

- `BACKGROUND_MODE` — neutral / preserve / custom
- `STYLIZATION` — subtle / medium / cute
- `MATERIAL_DETAIL` — simple / balanced / detailed

## 실패 기준

- 얼굴이 다른 사람처럼 바뀜
- 의상·표정·헤어가 임의 변경됨
- 과도한 아기 비율/거대 눈
- 브랜드 고유 캐릭터를 모사함
