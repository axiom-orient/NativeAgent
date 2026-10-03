---
id: IR-12
mode: REFERENCE_IMAGE_REQUIRED
category: travel-collage
---

# 사진 → 여행 스크랩북 콜라주

## 목적

인물/주 피사체를 고정 앵커로 사용해 여행 기억을 종이 스크랩북 콜라주로 구성한다.

## 입력

- 필수: 주 피사체 사진 1장
- 필수: 여행지/여행 요소 목록
- 선택: 날짜/짧은 캡션(정확한 문자열만)

## 범용 프롬프트

```text
Create a detailed travel scrapbook collage using the uploaded main subject as the central cutout.

REFERENCE AUTHORITY:
- Treat the uploaded image as the source of truth for identity, geometry, count, relative placement, pose/viewpoint, crop, and distinctive features unless the user explicitly asks to change them.
- Apply the requested visual transformation to the existing scene rather than silently redesigning it.
- If a detail is unclear, simplify it instead of inventing a replacement.
- Do not add text, logos, props, people, limbs, accessories, objects, or background elements unless explicitly requested.

SUBJECT:
- Preserve identity, outfit, pose, and recognizable silhouette of the uploaded subject.
- Treat the subject as one clean paper cutout; do not duplicate the person unless requested.

COLLAGE:
- Surround the subject with layered paper memories derived only from `TRIP_ELEMENTS`: small photos/illustrations, tickets, maps, labels, tape, torn paper, and simple travel ephemera.
- Use clear depth through overlap and paper shadows, but keep the central subject dominant.
- Use one cohesive palette and material system.
- Exact text may appear only from `EXACT_TEXT`; otherwise use no readable pseudo-writing.

Avoid random destinations, invented dates, fake brands, duplicate faces, excessive clutter, or photorealistic pasted objects that break the handmade collage look.
```

## 선택 변수

- `TRIP_ELEMENTS` — destination, activities, landmarks, memories
- `EXACT_TEXT` — optional exact words only
- `DENSITY` — minimal / balanced / dense

## 실패 기준

- 인물 중복/변형
- 사용자가 주지 않은 여행지·날짜 창작
- 가독 불가능한 가짜 텍스트 범람
- 레이어가 과도해 주 피사체가 묻힘
