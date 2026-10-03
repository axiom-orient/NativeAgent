# ASKTutor — 아키텍처

```text
consumer app → TutorKernel/use cases
              ├─ TutorModelClient / HTTP gateway
              ├─ Tutor store / mutation state
              └─ ASK knowledge read / approved insight apply
```

TutorKernel은 학습 domain entry다. learner/session/practice 상태는 Tutor store가 소유하고 ASK source/evidence/journal은 ASK가 소유한다. JSONFileTutorStore는 저장 adapter, HTTP gateway는 외부 I/O adapter다. UI·계정·전역 lifecycle은 소비 앱의 composition root에 둔다.

insight apply는 patch staging→명시 approved receipt→ASK commit→Tutor applied record→PageIndex→presentation→candidate cleanup 순서다. 각 저장소·외부 모델 호출은 별도 effect이며 하나의 전역 atomic transaction이 아니다. canonical commit 이후 실패는 committed record와 failed effect로 관찰·복구한다.

NativeAgent core의 직접 의존성이나 mandatory composition root를 추가하지 않는다. ASK를 사용하는 것은 지식 dependency이며 Agent 실행 state를 함께 소유한다는 뜻이 아니다.
