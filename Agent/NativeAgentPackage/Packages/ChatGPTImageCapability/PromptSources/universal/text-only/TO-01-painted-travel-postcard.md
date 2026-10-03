---
id: TO-01
mode: TEXT_ONLY
category: travel-generation
---

# 장소 설명 → 부드러운 회화 여행 엽서

## 목적

사진 없이 장소명과 핵심 요소만으로 범용 여행 엽서 일러스트를 생성한다.

## 입력

- 필수: PLACE
- 선택: LANDMARKS, SEASON, TIME, ASPECT_RATIO

## 범용 프롬프트

```text
Create an elegant travel postcard illustration of `PLACE` using a soft painted graphic style.

GENERATION DISCIPLINE:
- Build only from the supplied variables and description.
- Keep subject, setting, composition, medium, lighting, palette, and output treatment internally consistent.
- Do not add text, logos, watermarks, extra subjects, or decorative objects unless explicitly requested.
- Prefer a clear focal hierarchy over unnecessary detail.

- Show one iconic but geographically coherent view using only landmarks or landscape cues appropriate to `PLACE` and `LANDMARKS`.
- Use simplified clean shapes, soft brushed texture, restrained atmospheric depth, and a cohesive palette appropriate to `SEASON` and `TIME`.
- Make the destination recognizable without overcrowding the frame.
- Default to no text, no border, no stamps, no logos, and no invented signage.
- Do not combine unrelated landmarks that cannot plausibly appear together from one viewpoint.

Aim for a timeless collectible travel card rather than a tourist-ad montage.
```

## 선택 변수

- `PLACE` — city/region/site
- `LANDMARKS` — optional verified visual cues
- `SEASON` — optional
- `TIME` — morning/day/sunset/night
- `ASPECT_RATIO` — default 4:5

## 실패 기준

- 지리적으로 함께 보일 수 없는 랜드마크 합성
- 장소 식별성 부족
- 과도한 관광 광고 문구/아이콘
- 무관한 장식 추가
