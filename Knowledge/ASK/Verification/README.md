# ASK verification entrypoints

이 디렉터리는 ASK public surfaces를 독립적으로 소비하는 qualification/test host다. product app이나 Agent composition root가 아니다.

| Host | Purpose |
|---|---|
| FacadeConsumer | root ASK public API |
| DeepConsumer | optional public products |
| ScenarioConsumer | restart, history, budget와 adversarial scenarios |
| HWPSampleConsumer | host-supplied native document corpus |
| ProductionCorpusConsumer | host-supplied corpus/vault |
| LatencyProbe | representative latency measurement |
| OwnerChecks | selected production-source regression harness |
| ASKFM harnesses | Apple-specific model qualification |

ASK root에서 지원 host용 Scripts/verify-apple.sh, verify-consumers.sh, verify-scenarios.sh와 verify-hwp-samples.sh를 사용할 수 있다. 각 script의 source, input/corpus와 필요한 SDK/device를 먼저 확인한다. [OwnerChecks 안내](OwnerChecks/README.md)와 [HWP sample 안내](HWPSampleConsumer/README.md)는 harness별 scope와 제외 항목을 설명한다.

Harness 통과는 해당 package/source와 실행 조건의 증거다. root facade 전체, 실제 Apple model, full app, corpus 또는 OS behavior로 확대 해석하지 않는다. Credentials, 사용자 corpus, build cache와 실행 결과를 source package에 넣지 않는다.
