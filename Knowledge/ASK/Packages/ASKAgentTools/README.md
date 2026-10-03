# ASKAgentTools

ASK에 Agent 의존성을 넣지 않는 선택형 `ASKClient` → `ToolExecutor` adapter.
query/plan/receipt/knowledge는 ASK, 승인·effect journal은 NativeAgent가 소유한다.

`queryTool(typedQuery)`는 host가 고정한 query를 읽기 도구로 제공한다. 모델 arguments는 빈 object만 허용한다.
`prepare(command)`는 effect-free plan/dryRun을 수행해 plan/preview/tool을 반환한다.
mutation tool의 승인 정책은 requireApproval이고 actionID 외 인자는 허용하지 않는다.

사용 흐름: host가 preview 확인 → Agent에 tool 등록 → 실제 Agent approval → ASK apply → canonical receipt 반환.
ToolExecutor 직접 호출은 신뢰된 host의 책임이지 승인 절차를 구현한 다른 진입점이 아니다.
apply 오류는 actionID와 underlying error를 보존하고 outcomeUnknown으로 분류한다.
새 DB, background worker, 자동 retry, model-supplied workspace path는 없다.

```sh
swift test --package-path Knowledge/ASK/Packages/ASKAgentTools -Xswiftc -warnings-as-errors
```

위 명령은 workspace root 기준이다. 원본 ASK의 실제 swift-markdown dependency가 필요하다.
이번 환경에서는 swift-markdown repository resolve 단계의 Git cache/repository 오류로 7개 실제 ASK integration tests를 실행하지 못했다. [상세 ANALYSIS](ANALYSIS.md)를 참조한다.
문법/manifest 검사와 integration 성공을 구분한다. [검증](../../../../docs/verification/README.md)을 따른다.
