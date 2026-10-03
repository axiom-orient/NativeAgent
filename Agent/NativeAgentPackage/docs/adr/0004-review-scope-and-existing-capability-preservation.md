# ADR-0004 — 기존 capability를 복제하지 않고 통합 경계를 보존

## 상태

Accepted — 사용자 요청의 기존 동작·public contract 보존, 소비 앱 composition 및 후반의 제한된 리팩토링 범위에 대한 적용 결정. Siri 기능 추가·DB admission의 새 구현 방식은 미결정이다.

## 맥락

NativeAgent-ASK base와 donor를 상대 경로/bytes로 비교하면 donor-only 파일이 없고 prompt/skill/image는 동일하다. 같은 기능을 복사하면 중복 source·등록·수명·업데이트 owner가 생긴다. NativeAgent와 ASK는 서로 독립인 SDK이며 ASKTutor는 ASK knowledge를 사용하는 별도 domain이다. 가이드의 일반 아키텍처를 완성 앱으로 오해하면 core에 Siri/모델/공용 DB/통합 server를 넣게 된다.

## 결정

기존 catalog/skill/provider 실행 경로를 사용하고 실제 결함만 좁은 source/test 변경으로 수정한다. late effect의 관찰을 취소가 지우지 않게 하고, catalog 값 검증을 동일한 의미의 경계로 수렴한다. SDK·public API·현재 schema/pins·runtime Markdown과 독립 state owner를 보존한다. 기존 LEAP 차이는 관련 SDK/architecture 증거 없이 donor로 덮어쓰지 않는다.

소비 앱은 같은 domain API를 UI/agent/system surface에 연결한다. 구체 Siri projection/권한/UI/extension 및 long-running integration은 앱 요구 확정 후 결정한다. 이번 분석이 신규 시스템 기능의 승인을 뜻하지 않는다.

## 결과

병렬 image executor/catalog·공용 knowledge/session DB·새 composition package를 만들지 않는다. 코드/문서/시험을 통해 확인된 실패를 Current와 PLAN에 남긴다. 환경이 없는 검증을 stub으로 우회하지 않는다. 과거 실행 이력을 별도 정본 문서로 누적하지 않으며, 현재 실험의 source/log/diff는 검증 증거로 분리한다.
