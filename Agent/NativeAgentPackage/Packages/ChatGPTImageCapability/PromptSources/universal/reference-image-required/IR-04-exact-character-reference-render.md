---
id: IR-04
mode: REFERENCE_IMAGE_REQUIRED
category: character-reference
---

# 캐릭터 이미지 → 정체성 보존 재렌더

## 목적

기존 캐릭터의 디자인을 바꾸지 않고 새로운 렌더·배경·장면에 안전하게 재사용한다.

## 입력

- 필수: 캐릭터 기준 이미지 1장
- 필수: 원하는 장면/배경/렌더 방식 설명

## 범용 프롬프트

```text
Use the uploaded character image as the authoritative design reference and render that same character in the requested scene.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

CHARACTER LOCK:
- Preserve exact recognizable proportions, silhouette, facial structure, hairstyle, colors, materials, textures, outfit construction, accessories, markings, and design-specific asymmetries.
- Do not redesign, modernize, beautify, simplify, or reinterpret the character unless explicitly requested.
- New pose and camera angle are allowed only when they remain physically consistent with the reference design.

SCENE:
- Apply `SCENE_DESCRIPTION`, `CAMERA`, and `LIGHTING` to the environment while keeping the character design locked.
- Resolve unseen surfaces conservatively from visible evidence; avoid inventing major features.

OUTPUT:
- Keep material response and rendering style consistent across the whole character.
- No text, logo, watermark, extra accessories, costume swaps, or anatomy changes.
```

## 선택 변수

- `SCENE_DESCRIPTION` — target action/environment
- `CAMERA` — shot size and angle
- `LIGHTING` — lighting description

## 실패 기준

- 캐릭터의 비율/색/재질/의상이 바뀜
- 보이지 않던 부분을 과도하게 창작함
- 새 액세서리나 마킹이 추가됨
- 장면 변화가 캐릭터 디자인 변화로 번짐
