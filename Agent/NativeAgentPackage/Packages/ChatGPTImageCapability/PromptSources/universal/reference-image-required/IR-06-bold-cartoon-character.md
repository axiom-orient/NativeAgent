---
id: IR-06
mode: REFERENCE_IMAGE_REQUIRED
category: character-transform
---

# 사진 → 대담한 그래픽 카툰 캐릭터

## 목적

원본 인물의 식별성을 유지하면서 굵은 선과 과장된 그래픽 형태의 카툰으로 변환한다.

## 입력

- 필수: 인물 사진 1장
- 선택: 과장 강도, 팔레트

## 범용 프롬프트

```text
Turn the uploaded subject into a bold graphic cartoon character while keeping the person clearly recognizable.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

- Preserve facial landmarks, hairstyle, skin tone, expression, outfit identity, and pose.
- Use confident outlines, simplified planar shapes, selective exaggeration, and a bright but controlled palette.
- Exaggerate only features that remain compatible with the person's identity; never deform the face arbitrarily.
- Keep shading minimal and graphic.
- Use a simple background unless the original environment is important.

Avoid anime defaults, caricature distortion, random accessories, text, logos, and changes to age or identity.
```

## 선택 변수

- `EXAGGERATION` — low / medium / high
- `PALETTE` — source-derived / bright / muted
- `BACKGROUND_MODE` — simple / preserve

## 실패 기준

- 과장 때문에 인물 식별성이 사라짐
- 얼굴·나이·성별 표현이 임의 변경됨
- 의상/포즈가 이유 없이 바뀜
- 과도한 음영으로 그래픽성이 사라짐
