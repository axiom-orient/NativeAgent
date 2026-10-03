# ADR-0001 — DecisionMemory와 bounded vectorless RAG

## 상태

**Accepted.** DecisionMemory와 bounded retrieval의 authority 경계를 정의한다.

## 맥락

ASK는 문서 index 자체를 권한 시스템으로 만들지 않으면서 지속적인 제약·절차를 기억해야 한다. 필수 embedding이나 무제한 prompt 없이도 원문에 근거한 제한된 retrieval이 필요하다.

## 결정

저장 lifetime `STIM → MTEM → LTSM`과 인지/제어 loop `State → Model → Hypothesize → Verify → Decide/Intervene → Act → Observe → Consolidate`를 분리한다.

immutable records/transitions를 canonical JSON으로 저장한다. 생성 Markdown은 재구축 가능한 projection이며 truth로 병합하지 않는다. `TaskFrame` context는 명시적 scope/token budget으로 결정적으로 compile하고 compiler 자체는 model/embedding을 호출하지 않는다.

`InterventionDecision`은 데이터로 반환한다. 수신 workflow가 `Act`를 소유하며 `block`, `requireVerification`, `remind`를 명시적으로 해석한다.

PageIndex는 source-bound evidence escalation에 사용한다. navigator는 host가 주입할 수 있고 JSON schema·source version·depth/visits/raw-evidence tokens/model calls의 제한을 지켜야 한다. `MarkdownSyntax`는 exact `swift-markdown` 0.8.0 경계를 사용하고 lockfile의 cmark-gfm-backed parser pin을 유지한다.

추출 provenance 부재는 `unsupported`, image-only PDF의 텍스트 요구는 `ocrRequired`로 구분하여 해당 evidence retrieval을 차단한다.

## 결과

광범위한 semantic recall보다 출처를 추적할 수 있는 bounded context를 우선한다. WorkWiki는 memory advice를 조합하는 경계이고 KnowledgeRuntime은 PageIndex/EvidenceIndex에 의존하지 않는다. source retrieval 결과가 암묵적으로 canonical memory truth가 되지 않는다. public API와 오류 조건은 [ASK 규격](SPEC.md), [KnowledgeRuntime](../Packages/KnowledgeRuntime/Package.swift), [PageIndex](../Packages/PageIndex/Package.swift)와 해당 source가 정본이다.
