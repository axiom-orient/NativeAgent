# ASK 아키텍처

ASK는 소비 앱이 선택해 조립하는 headless knowledge SDK다.

```text
ASKClient
├── ASKApplication       process-local mutation leases and WorkWiki runtime cache
├── WorkWiki             proposal and decision workflow
├── KnowledgeRuntime     canonical journal, CAS and replay
├── PageIndex            source identity, version and history
├── EvidenceIndex        evidence query and freshness
└── KnowledgePresentation derived reading views

Optional products: documents · capture · wiki · MCP · FoundationModels · ASKTutor
```

[Package catalog](../Packages/README.md)는 SwiftPM product와 각 public boundary를 나열한다. `Package.swift`가 실제 dependency와 platform의 정본이다.

## Authority

| Concern | Owner |
|---|---|
| root request plan/apply/query | ASK root API |
| same-process root admission, WorkWiki runtime cache | ASKApplication; process-local 범위 |
| source identity, version, history | PageIndex |
| exact/current evidence | EvidenceIndex |
| approved knowledge, receipt, CAS, replay | KnowledgeRuntime |
| derived reading/presentation | KnowledgePresentation |
| proposal/decision workflow | WorkWiki |
| learner/session/practice state | ASKTutor |

Derived views와 format adapters는 canonical journal을 대신하지 않는다. ASK root, source publication, journal과 tutoring stores는 별도 commit boundary이며 global transaction을 약속하지 않는다. 한 workspace의 동시 root writes와 하위 direct writers의 조정은 host가 맡는다.

일반 command/query는 `ASKClient` 한 곳으로 들어온다. `ASKApplicationRuntime`은 명시적 `ASKApplicationConfiguration`의 workspace에 mutation lease와 WorkWiki runtime cache를 제공하는 하위 조정 계층이다. 자체 Agent query, JSON bridge나 별도 workflow router를 제공하지 않는다.

## 선택 경계

MCP는 external transport다. FoundationModels는 선택 observation adapter다. Document, SourceCapture, MarkdownWiki와 UI packages는 별도 public contracts를 가진다. ASKTutor는 ASK knowledge를 읽지만 tutoring state를 독립 소유한다. NativeAgent가 필요한 경우 consumer app이 두 SDK를 직접 조립한다.

root `ASKClient.query`의 no-hidden-write 계약을 하위 library의 직접 materialization API에 자동 확장하지 않는다. 각 호출 surface는 자기 공개 계약과 host 권한을 따른다.
