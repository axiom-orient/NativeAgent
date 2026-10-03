---
id: IR-07
mode: REFERENCE_IMAGE_REQUIRED
category: character-transform
---

# 사진 → 귀여운 3D 캐릭터 장면

## 목적

원본의 의상·환경·표정·포즈까지 유지하면서 귀여운 3D 캐릭터 장면으로 변환한다.

## 입력

- 필수: 사진 1장
- 선택: 귀여움 강도, 배경 단순화 정도

## 범용 프롬프트

```text
Convert the uploaded photo into a cute compact 3D animated-character scene.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

- Preserve the same clothing, environment layout, facial expression, body pose, camera viewpoint, and subject placement.
- Preserve identity and distinctive accessories.
- Apply a gentle stylized 3D treatment: rounded forms, clean materials, soft lighting, simplified textures, and slightly reduced proportions.
- Keep the original environment recognizable but simplify noisy details.
- Do not move the subject to a studio or invent a new setting unless requested.

Avoid extreme chibi proportions, giant eyes, costume changes, face replacement, extra props, text, or logos.
```

## 선택 변수

- `CUTENESS` — subtle / medium / strong
- `ENVIRONMENT_DETAIL` — preserve / simplified

## 실패 기준

- 원본 배경이 다른 장소로 교체됨
- 포즈·표정·의상 불일치
- 지나친 치비화
- 식별 가능한 특징 손실
