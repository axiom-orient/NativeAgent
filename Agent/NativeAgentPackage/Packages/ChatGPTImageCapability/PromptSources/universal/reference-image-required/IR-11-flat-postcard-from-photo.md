---
id: IR-11
mode: REFERENCE_IMAGE_REQUIRED
category: postcard-transform
---

# 사진 → 플랫 디자인 여행 엽서

## 목적

사진의 장소와 구도를 유지하면서 텍스트 없는 플랫 그래픽 여행 엽서로 변환한다.

## 입력

- 필수: 장소/풍경 사진 1장
- 선택: 출력 비율, 디테일 수준, 팔레트

## 범용 프롬프트

```text
Transform the uploaded travel photograph into a detailed flat-design postcard illustration.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

- Preserve the same location, landmark identity, horizon, major architecture/natural forms, camera viewpoint, and composition.
- Simplify photographic detail into clean layered shapes, controlled edges, limited shading, and a cohesive source-derived palette.
- Retain enough local detail that the place remains unmistakably recognizable.
- Remove transient clutter only when it is not essential to the scene.
- No border, caption, typography, stamp, logo, watermark, or invented landmark.

Output in `ASPECT_RATIO` while preserving composition through minimal crop rather than redesign.
```

## 선택 변수

- `ASPECT_RATIO` — default 9:16; may be 4:5, 3:2, etc.
- `DETAIL` — clean / detailed
- `PALETTE` — source-derived / warm / cool

## 실패 기준

- 랜드마크 형태가 바뀜
- 임의 텍스트/프레임 추가
- 시점 재구성
- 장소를 일반적인 여행 풍경으로 대체
