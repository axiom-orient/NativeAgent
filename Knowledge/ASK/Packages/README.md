# ASK SwiftPM packages

이 catalog는 package 선택을 돕는다. 실제 product, platform, dependency와 target graph는 연결된 `Package.swift`가 정본이다. root `ASK` product가 기본 command/query API를 제공하며 optional package는 필요한 consumer만 추가한다.

| Package | Product | 책임과 경계 |
|---|---|---|
| [ASK root](../Package.swift) | `ASK` | `ASKClient` root command/query composition surface |
| [ASKApplication](ASKApplication/Package.swift) | `ASKApplication` | `ASKClient` 아래의 process-local mutation lease와 WorkWiki runtime cache. 명시적 `ASKApplicationConfiguration`을 받으며 별도 command/query facade를 제공하지 않는다. Fail-fast admission은 cross-process transaction이나 queue가 아니다. |
| [KnowledgeCore](KnowledgeCore/Package.swift) | `KnowledgeCore` | 순수 source, identity, evidence, patch/receipt와 memory contracts |
| [KnowledgeRuntime](KnowledgeRuntime/Package.swift) | `KnowledgeRuntime`, `DecisionMemory` | canonical journal, CAS, replay, raw/representation persistence와 별도 memory library |
| [KnowledgeHealth](KnowledgeHealth/Package.swift) | `KnowledgeHealth` | canonical, derived와 evidence storage health의 합성 |
| [PageIndex](PageIndex/Package.swift) | `PageIndex` | source identity/version/history, artifacts와 retrieval. Default file identity는 canonical path 기반이다. |
| [EvidenceIndex](EvidenceIndex/Package.swift) | `EvidenceIndex` | freshness와 검색 결과를 typed evidence pack으로 제공 |
| [WorkWiki](WorkWiki/Package.swift) | `WorkWiki` | report, close-day와 capture proposal/decision workflow 및 승인 전 source guards |
| [KnowledgePresentation](KnowledgePresentation/Package.swift) | `KnowledgePresentation` | derived bundle publication, reading context와 source bridge |
| [DocumentCore](DocumentCore/Package.swift) | `DocumentCore`, `MarkdownSyntax` | 순수 document values와 compile/render/export; file I/O는 별도 경계다. |
| [DocumentRuntime](DocumentRuntime/Package.swift) | `DocumentRuntime` | manifest, selection과 contained file loading |
| [DocumentUI](DocumentUI/Package.swift) | `DocumentUI` | SwiftUI document/HWP presentation과 asynchronous view state |
| [HTMLDocument](HTMLDocument/Package.swift) | `HTMLDocument` | HTML decoding, DOM/selector와 text extraction; public API 이름은 manifest/source에 따른다. |
| [HWPDocument](HWPDocument/Package.swift) | `HWPDocument` | HWP5/HWPX parsing, layout와 export. PageIndex 기본 ingestion과 자동 결합되지 않는다. |
| [SourceCapture](SourceCapture/Package.swift) | `SourceCapture` | HTTP/HTML capture를 staging 경계로 제공. Trusted direct runtime API는 별도 effect surface다. |
| [MarkdownWiki](MarkdownWiki/Package.swift) | `MarkdownWiki` | 직접 파일을 편집하는 wiki의 단일 product. 별도 package를 직접 의존하며 journal-derived wiki와 상태·쓰기 계약이 다르다. |
| [ASKMCP](ASKMCP/Package.swift) | `ASKMCP`, `ask-mcp`, `ask-mcp-http` | 외부 MCP adapter와 executables. Read-only가 기본이고 staging은 proposal/repair/rebuild/DecisionMemory effects를 허용하지만 bundled commit과 approval은 숨긴다. Full은 operator identity가 필요하다. HTTP는 loopback에 bind하며 bearer token 미설정 시 해당 loopback endpoint는 allow-all authorization을 사용한다. |
| [ASKFoundationModels](ASKFoundationModels/Package.swift) | `ASKFoundationModels` | Apple Foundation Models 기반 선택 observation tools; canonical knowledge writer가 아니다. |
| [ASKTutor](ASKTutor/Package.swift) | `ASKTutor` | ASK-backed learner/session/practice/evaluation/plan domain. 자세한 사용 예는 [ASKTutor 안내](ASKTutor/README.md). |

앱 composition, UI, 계정, permission과 storage placement는 이 catalog나 SDK workspace가 소유하지 않는다. 소비 앱이 필요한 products를 직접 연결한다.
