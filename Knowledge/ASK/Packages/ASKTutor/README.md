# ASKTutor

**ASK-backed structured tutoring domain SDK.** learner/session/practice/grade/plan·insight workflow를 소유하고, 지식의 진실은 ASK가 소유한다.

production entry:

```swift
TutorKernel(
    ask: ASKConfiguration(...),
    model: tutorModelClient,
    store: tutorStore
)
```

arbitrary knowledge provider는 public API가 아니다. deterministic test injection만 module 내부에서 허용한다.

ASKTutor은 NativeAgent의 필수 dependency가 아니며 first-party 앱에 억지로 통합하지 않는다. Agent chat과 structured tutoring은 서로 다른 state scope다.

[ASK 규격](../../docs/SPEC.md) · [ASK 아키텍처](../../docs/ARCHITECTURE.md) · [package catalog](../README.md)

## 정본 문서

[IDENTITY](docs/IDENTITY_AND_EVOLUTION.md) · [SPEC](docs/SPEC.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) · [IMPLEMENTATION_STATUS](docs/IMPLEMENTATION_STATUS.md) · [PLAN](docs/PLAN.md)
