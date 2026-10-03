# Migration Hold — 활성 제품 아님

`AppleLocalAI`는 기존 public structured/macros/audio/profile/local backend 기능을 보존한다.
새 text façade와 동등하다고 검증하지 않았으므로 [P8 조건](../docs/PLAN.md) 충족 전 삭제하지 않는다.
모든 활성 package는 이 디렉터리에 의존하지 않는다. 이곳을 기본 provider 선택 경로로 등록하지 않는다.

`NativeAgentRelease`는 옛 monolithic release workflow와 과거 qualification 선언이다.
현재 source bundle을 게시/검증하는 도구가 아니며 그대로 실행하지 않는다.
[현재 검증](../docs/verification/README.md)만 이번 작업의 상태를 소유한다.
