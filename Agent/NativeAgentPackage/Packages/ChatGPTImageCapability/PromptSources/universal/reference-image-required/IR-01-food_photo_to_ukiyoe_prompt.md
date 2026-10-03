---
id: IR-01
mode: REFERENCE_IMAGE_REQUIRED
category: food-style-transfer
---

# 음식 사진 → 전통 일본 목판화 정물

## 목적

음식의 정체성과 플레이팅을 유지하면서 사진적 표현만 에도시대 음식 정물 목판화 언어로 변환한다.

## 입력

- 필수: 음식 사진 1장
- 선택: 서예 문구, 인장 사용 여부, 배경 보존 정도

## 범용 프롬프트

```text
Transform the uploaded food photograph into a refined traditional Japanese woodblock-print food still life inspired by Edo-period food prints and surimono.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

FOOD FIDELITY:
- Preserve the exact cuisine, dish identity, ingredient count, vessel shapes, plating, garnish placement, camera viewpoint, crop, and major color relationships.
- Do not convert non-Japanese cuisine into Japanese cuisine.
- Do not invent side dishes, utensils, ingredients, decorative tableware, scenery, waves, mountains, flowers, or cultural motifs.

PRINT LANGUAGE:
- Translate photographic detail into flat hand-printed color fields, thin-to-medium sumi-like contours, restrained carved-line detail, and slightly simplified dimensional modeling.
- Use subtle woodgrain, dry-print texture, gentle ink absorption, and slightly imperfect registration.
- Use a restrained palette derived from the source: muted indigo, teal, vermilion, iron red, ochre, warm brown, moss green, charcoal, warm ivory, and faded beige.
- Keep important food colors recognizable while reducing saturation and tonal range.
- Remove glossy reflections, HDR, lens blur, shallow depth of field, cinematic grading, plastic surfaces, and modern 3D shading.

PAPER AND BACKGROUND:
- Render on warm off-white handmade washi with subtle fibers, mild age variation, and very light foxing.
- Preserve only background elements essential to the presentation; otherwise simplify toward quiet negative space.

TEXT POLICY:
- By default, add no writing, signatures, seals, logos, or pseudo-characters.
- If exact calligraphy text is explicitly supplied, place only that text in available negative space with one small red seal if requested.

QUALITY TARGET:
The result should look carefully printed on paper: quiet, tactile, flat, restrained, slightly aged, compositionally precise, and immediately recognizable as the same food scene.
```

## 선택 변수

- `CALLIGRAPHY_TEXT` — exact text to render; omit by default
- `ADD_SEAL` — yes/no; default no
- `BACKGROUND_RETENTION` — minimal / partial / preserve

## 실패 기준

- 음식 종류나 요리 문화권이 바뀜
- 음식/그릇 개수, 배치, 시점, 크롭이 달라짐
- 임의의 일본어·로고·인장·장식이 추가됨
- 디지털 페인팅/애니/3D 렌더처럼 보임
- 종이 오염이나 노화가 음식보다 강해짐

## 메모

음식 이미지 변환을 패키지 공통 규격으로 정의한 canonical prompt다.
