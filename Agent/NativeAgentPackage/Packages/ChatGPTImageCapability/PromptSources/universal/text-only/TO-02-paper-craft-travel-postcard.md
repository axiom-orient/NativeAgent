---
id: TO-02
mode: TEXT_ONLY
category: travel-generation
---

# 목적지 → 미니어처 종이공예 여행 엽서

## 목적

여행지를 손으로 자르고 접은 종이 미니어처처럼 표현한다.

## 입력

- 필수: DESTINATION
- 선택: LANDMARKS, PALETTE, ASPECT_RATIO

## 범용 프롬프트

```text
Create a charming miniature paper-craft travel illustration of `DESTINATION`, designed as a delicate handmade postcard.

GENERATION DISCIPLINE:
- Build only from the supplied variables and description.
- Keep subject, setting, composition, medium, lighting, palette, and output treatment internally consistent.
- Do not add text, logos, watermarks, extra subjects, or decorative objects unless explicitly requested.
- Prefer a clear focal hierarchy over unnecessary detail.

- Build the scene from layered cut paper, folded cardstock, small tabs, visible paper edges, and subtle cast shadows.
- Represent `LANDMARKS` with simplified but recognizable silhouettes and coherent scale.
- Use a compact diorama-like composition with a clear foreground, middle layer, and backdrop.
- Materials should look tactile and handcrafted, not like glossy 3D plastic.
- Default to no text, border, logo, stamp, or watermark.

Keep the model physically plausible as a paper object and avoid unrelated souvenir clutter.
```

## 선택 변수

- `DESTINATION` — place
- `LANDMARKS` — optional list
- `PALETTE` — source/location inspired
- `ASPECT_RATIO` — default 4:5

## 실패 기준

- 종이공예가 아니라 일반 3D 렌더가 됨
- 랜드마크 왜곡/혼합
- 불필요한 텍스트/기념품 추가
- 레이어 구조가 물리적으로 모순
