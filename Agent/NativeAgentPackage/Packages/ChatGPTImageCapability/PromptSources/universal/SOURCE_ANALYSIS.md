# Source Analysis

## 결론

검토된 prompt source는 아이디어는 유용하지만, 그대로 재사용하기에는 네 가지 공통 결함이 있었다.

1. **맥락 종속**: 특정 도시(Moscow), 특정 브랜드/서비스(Pixar, Charlie and Lola, Zalo, Polaroid, Gemini)에 결박된 표현이 존재했다.
2. **불완전성**: 검색 색인 발췌 기반이라 다수 문장이 중간에서 잘려 있었다.
3. **입력 권위 부재**: “같은 얼굴/옷/환경” 같은 보존 의도는 있으나 무엇이 source of truth인지, 무엇까지 변경 가능한지 명시가 약했다.
4. **출력 검증 부재**: 프롬프트마다 실패 조건, 텍스트 정책, 임의 추가 금지, 변수 체계가 달랐다.

## 상호 고도화에 사용한 패턴

- **exact reference** 개념을 모든 이미지 변환 프롬프트의 `REFERENCE AUTHORITY`로 확장했다.
- 의상·환경·표정·포즈 보존을 변환형 프롬프트의 **구체적 fidelity 목록**으로 표준화했다.
- 얼굴 보존 의도를 portrait 계열 전체의 **identity lock**으로 확장했다.
- film grain·contrast·flash 요소를 서로 분리해 **analog film mechanism**과 **lighting mechanism**이 섞이지 않게 했다.
- 사진→flat postcard와 텍스트만으로 생성하는 여행 프롬프트를 분리했다.
- 콜라주 개념은 **중앙 피사체 정체성 보존**과 **사용자 제공 micro-story만 생성**하는 규칙으로 강화했다.
- 음식 이미지의 **원본 구조 보존 / 스타일만 변환 / 임의 장식 금지** 규칙을 다른 스타일 변환 프롬프트에도 적용했다.

## 모드 판정

### REFERENCE_IMAGE_REQUIRED
identity, geometry, composition, food/plating, place view, subject pose처럼 **기준 이미지의 시각 정보 보존이 목적의 일부**인 경우.

### TEXT_ONLY
장소/피사체/장면을 처음부터 생성할 수 있고 기존 픽셀·정체성을 보존할 필요가 없는 경우.

## 원본 검증 상태

외부 source의 의미·품질은 이 저장소의 정적 검증 범위를 넘는다. 따라서 이 패키지는 외부 원문을 runtime에 복원하지 않고, 검토된 **사용 의도를 canonical prompt로 재설계**한다.
