---
id: TO-03
mode: TEXT_ONLY
category: travel-generation
---

# 목적지 → 미니어처 3D 여행 디오라마

## 목적

특정 도시명에 종속되지 않는 미니어처 여행 디오라마 프롬프트.

## 입력

- 필수: DESTINATION
- 선택: LANDMARKS, BASE_SHAPE, MATERIAL_STYLE, TIME

## 범용 프롬프트

```text
Create a refined miniature travel diorama inspired by `DESTINATION`, presented like a collectible handmade postcard object.

GENERATION DISCIPLINE:
- Build only from the supplied variables and description.
- Keep subject, setting, composition, medium, lighting, palette, and output treatment internally consistent.
- Do not add text, logos, watermarks, extra subjects, or decorative objects unless explicitly requested.
- Prefer a clear focal hierarchy over unnecessary detail.

- Build a compact freestanding or floating base containing a coherent miniature interpretation of `LANDMARKS`.
- Use believable miniature scale, clean object hierarchy, controlled depth, and carefully separated silhouettes.
- Materials should follow `MATERIAL_STYLE` consistently, such as painted wood, paper craft, ceramic, or matte model-making materials.
- Lighting should be soft and product-like while respecting `TIME`.
- Keep decorative travel symbols minimal and destination-specific.
- No text or logo unless exact wording is provided.

Avoid mixing multiple incompatible craft materials or turning the scene into a generic fantasy city.
```

## 선택 변수

- `DESTINATION` — place
- `LANDMARKS` — optional list
- `BASE_SHAPE` — narrow / circular / book-like / custom
- `MATERIAL_STYLE` — paper / wood / ceramic / matte miniature
- `TIME` — day / sunset / night

## 실패 기준

- 장소 고유성이 사라짐
- 미니어처 스케일 불일치
- 재질이 뒤섞여 조형 언어가 불명확
- 기념품/아이콘 과다
