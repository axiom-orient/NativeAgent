# Retained Monolithic Release Workflow

과거 NativeAgent 단일 subtree 배포 규칙을 보존한다. 현재 NativeAI graph의 release tool이 아니다.
`release/` 선언은 입력의 과거 기록이며 새 source qualification으로 해석하지 않는다.
`scripts/release.py`를 현재 제품 packaging에 실행하지 않는다.
workspace `tools/test-release-boundary.py`는 이 분류 함수의 회귀만 검사한다.
