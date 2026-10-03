# FoundationModelsBridge — Apple 27, text-only

선택한 `FoundationModels.LanguageModel`을 NativeAI `LanguageModelCore.LanguageModel`로 투영한다.
Core/Runtime에서 Apple module을 import하지 않도록 격리한 선택형 package다.

`FoundationLanguageModel(model:providerID:modelID:displayName:)`은 immutable native binding을 만든다.
Executor는 exact text transcript를 호출별 native session에 전달하고 await한 실제 응답만 완료 event로 보낸다.
별도 model loader/history store/producer Task나 역방향 bridge를 만들지 않는다.

현재 지원: text input/output. 미지원: incremental delta, tools, guided output, vision, reasoning, sampling option.
native model에 기능이 있더라도 이 bridge가 정확히 전달하지 못하면 capability를 선언하지 않는다.

`canImport(FoundationModels, _version: 2)`와 OS 27 availability를 모두 요구한다.
Linux에서는 native 본문이 제외된다. 해당 build 성공은 SDK signature/link/inference 검증이 아니다.
[SDK gate](../../docs/PLAN.md) 이전에는 production-ready로 취급하지 않는다.
