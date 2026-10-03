import Foundation
import EvidenceIndex
import DocumentCore
import KnowledgeRuntime
import KnowledgeHealth
import KnowledgePresentation
import PageIndex
import WorkWiki

extension ASKClient {
    func queryValidated(_ query: ASKQuery) async throws -> ASKQueryResult {
        try ASKCommandPlanner.validateFileRoutes(
            configuration: configuration,
            selection: query.workspaceSelection
        )
        switch query {
        case .groundedEvidence(let value):
            try validateLimit(value.limit)
            let paths = resolvedPaths(value.workspace)
            let index = try await ASKEvidenceIndex.open(workspaceURL: paths.indexURL)
            return .groundedEvidence(try await index.buildGroundedPack(
                ASKEvidenceQuery(text: try nonempty(value.text, field: "text"), limit: value.limit),
                maxBytes: value.maxBytes, freshnessRequirement: value.freshnessRequirement
            ))

        case .resolveEvidence(let value):
            let paths = resolvedPaths(value.workspace)
            let index = try await ASKEvidenceIndex.open(workspaceURL: paths.indexURL)
            return .resolvedEvidence(try await index.resolve(
                value.reference, freshnessRequirement: value.freshnessRequirement
            ))

        case .searchEvidence(let value):
            try validateLimit(value.limit)
            let paths = resolvedPaths(value.workspace)
            let hits = try await ASKEvidenceIndex.open(workspaceURL: paths.indexURL).search(
                ASKEvidenceQuery(text: try nonempty(value.text, field: "text"), limit: value.limit)
            )
            return .evidenceSearch(ASKSearchResult(items: hits.map {
                ASKSearchItem(
                    id: $0.nodeID,
                    sourceID: $0.sourceID.rawValue,
                    nodeID: $0.nodeID,
                    revision: $0.sourceVersionChecksum,
                    rangeStart: $0.range.start,
                    rangeEnd: $0.range.end,
                    freshness: $0.freshness.rawValue,
                    title: $0.title,
                    excerpt: $0.excerpt
                )
            }))

        case .searchKnowledge(let value):
            try validateLimit(value.limit)
            let paths = resolvedPaths(value.workspace)
            guard FileManager.default.fileExists(atPath: paths.vaultURL.path) else {
                return .knowledgeSearch(ASKSearchResult(items: []))
            }
            let hits = try ASKRuntime(root: paths.vaultURL)
                .search(try nonempty(value.text, field: "text"), limit: value.limit)
                .hits
            return .knowledgeSearch(ASKSearchResult(items: hits.map {
                ASKSearchItem(
                    id: $0.docID,
                    projectionSlug: $0.projectionSlug,
                    title: $0.title,
                    excerpt: $0.snippet
                )
            }))

        case .retrieveEvidence(let value):
            let question = try nonempty(value.question, field: "question")
            try validatePositive(value.maxSources, field: "maxSources")
            try validatePositive(value.maxTreeDepth, field: "maxTreeDepth")
            try validatePositive(value.maxVisitedNodes, field: "maxVisitedNodes")
            try validatePositive(value.maxRawEvidenceTokens, field: "maxRawEvidenceTokens")
            let paths = resolvedPaths(value.workspace)
            let store = try SourceIndexStore(workspaceURL: paths.indexURL)
            let artifacts = try await store.snapshot()
            let selection: SourceSelection
            if value.sourceIDs.isEmpty {
                selection = .scoped(corpusScope: SourceCorpusScope(maxSources: value.maxSources))
            } else {
                selection = .exact(sourceIDs: value.sourceIDs.map { SourceID($0) })
            }
            let retrieved = try await VectorlessTreeRAG().retrieve(
                query: SourceEvidenceQuery(
                    sourceSelection: selection,
                    question: question,
                    maxTreeDepth: value.maxTreeDepth,
                    maxVisitedNodes: value.maxVisitedNodes,
                    maxRawEvidenceTokens: value.maxRawEvidenceTokens,
                    maxModelCalls: 0
                ),
                artifacts: artifacts
            )
            return .evidenceRetrieved(ASKEvidenceRetrieveResult(
                answerability: retrieved.answerability.rawValue,
                evidence: retrieved.excerpts.map { excerpt in
                    ASKRAGEvidenceItem(
                        sourceID: excerpt.anchor.sourceID.rawValue,
                        sourceVersionChecksum: excerpt.anchor.sourceVersionChecksum,
                        nodeID: excerpt.anchor.nodeID,
                        rangeStart: excerpt.anchor.range.start,
                        rangeEnd: excerpt.anchor.range.end,
                        excerptIndex: excerpt.index,
                        content: excerpt.content
                    )
                },
                selectedSourceIDs: retrieved.trace.selectedSourceIDs.map(\.rawValue),
                visitedNodeIDs: retrieved.trace.visitedNodeIDs,
                rawEvidenceTokens: retrieved.trace.rawEvidenceTokens,
                diagnostics: retrieved.trace.diagnostics
            ))

        case .projection(let value):
            let slug = try nonempty(value.slug, field: "slug")
            let paths = resolvedPaths(value.workspace)
            guard FileManager.default.fileExists(atPath: paths.vaultURL.path),
                  let document = try ASKRuntime(root: paths.vaultURL).projectionDocument(slug: slug) else {
                throw ASKDiagnostic(
                    code: .notFound,
                    operation: .query,
                    message: "Projection not found: \(slug)",
                    context: ["slug": slug],
                    recovery: .correctInput
                )
            }
            return .projection(ASKProjectionResult(
                slug: document.slug,
                title: document.title,
                body: document.bodyMD
            ))

        case .markdownPage(let value):
            let markdown = try nonempty(value.markdown, field: "markdown")
            let document = ASKPageMarkdownCompiler().compile(
                markdown: markdown,
                documentID: ASKPageDocumentID(value.documentID),
                sourceID: ASKPageSourceID(value.sourceID),
                title: value.title
            )
            return .markdownPage(ASKMarkdownPageResult(
                title: document.title,
                sectionCount: document.sections.count,
                blockCount: document.blocks.count
            ))

        case .readingContext(let value):
            let slug = try nonempty(value.projectionSlug, field: "projectionSlug")
            let paths = resolvedPaths(value.workspace)
            let runtime = try ASKKnowledgeWorkspaceRuntime(
                workspace: ASKKnowledgeWorkspacePaths(rootURL: paths.productWorkspaceURL),
                knowledgeRootURL: paths.vaultURL,
                allowsReadMaterialization: false,
                createsWorkspace: false
            )
            let context = try await runtime.loadProjectionReadingContext(slug: slug)
            return .readingContext(ASKReadingContextResult(
                projectionSlug: context.presentation.projection.slug,
                title: context.presentation.projection.title,
                bundleRootURL: context.presentation.bundleRootURL,
                sourceCatalogCount: context.sourceCatalogs.count,
                catalogEntryCount: context.catalogEntries.count,
                resolvedBacklinkCount: context.backlinkAudit.resolved.count,
                unresolvedBacklinkCount: context.backlinkAudit.unresolved.count
            ))

        case .storageHealth(let value):
            let paths = resolvedPaths(value.workspace)
            guard FileManager.default.fileExists(atPath: paths.vaultURL.path)
                    || FileManager.default.fileExists(atPath: paths.indexURL.path) else {
                return .storageHealth(ASKStorageHealthResult(
                    isHealthy: false,
                    components: [
                        ASKStorageComponentStatus(component: "vault", state: "missing"),
                        ASKStorageComponentStatus(component: "evidence", state: "missing"),
                    ]
                ))
            }
            let report = try await ASKKnowledgeStorageHealthIntegration.makeStorageHealthRuntime(
                vaultURL: paths.vaultURL,
                evidenceIndexURL: paths.indexURL
            ).healthReport()
            return .storageHealth(ASKStorageHealthResult(
                isHealthy: report.isHealthy,
                components: report.derivedFreshness.map {
                    ASKStorageComponentStatus(component: $0.component.rawValue, state: $0.state.rawValue)
                }
            ))

        case .pendingWork(let value):
            let paths = resolvedPaths(value.workspace)
            let patches: [ASKPendingPatchItem]
            if FileManager.default.fileExists(atPath: paths.vaultURL.path) {
                patches = try ASKRuntime(root: paths.vaultURL).pendingPatchPlans()
                    .map { plan in
                        ASKPendingPatchItem(
                            patchID: plan.patchID,
                            kind: plan.patchKind.rawValue,
                            generatedAt: plan.generatedAt,
                            title: plan.projectionWrites.first?.document.title
                        )
                    }
                    .sorted {
                        if $0.generatedAt != $1.generatedAt {
                            return $0.generatedAt < $1.generatedAt
                        }
                        return $0.patchID < $1.patchID
                    }
            } else {
                patches = []
            }
            let repairs = try ASKPresentationRepairStore(
                productWorkspaceURL: paths.productWorkspaceURL
            ).pendingTokens()
            return .pendingWork(ASKPendingWorkResult(
                patches: patches,
                presentationRepairs: repairs
            ))

        case .sourceInspect(let value):
            let sourceID = SourceID(try nonempty(value.sourceID, field: "sourceID"))
            if let start = value.start, start <= 0 {
                throw invalidRange(field: "start", value: start)
            }
            if let end = value.end, end <= 0 {
                throw invalidRange(field: "end", value: end)
            }
            if let start = value.start, let end = value.end, end < start {
                throw ASKDiagnostic(
                    code: .invalidRequest,
                    operation: .query,
                    message: "end must be greater than or equal to start",
                    context: ["start": String(start), "end": String(end)],
                    recovery: .correctInput
                )
            }
            let paths = resolvedPaths(value.workspace)
            let store = try SourceIndexStore(workspaceURL: paths.indexURL)
            let selected: SourceIndexArtifact?
            if let checksum = value.sourceVersionChecksum {
                selected = try await store.get(sourceID: sourceID,
                    versionChecksum: nonempty(checksum, field: "sourceVersionChecksum"))
            } else {
                selected = try await store.get(sourceID: sourceID)
            }
            guard let artifact = selected else {
                throw ASKDiagnostic(
                    code: .notFound,
                    operation: .query,
                    message: "Requested source version not found: \(sourceID.rawValue)",
                    context: ["sourceID": sourceID.rawValue,
                              "sourceVersionChecksum": value.sourceVersionChecksum ?? "current"],
                    recovery: .correctInput
                )
            }
            let first = value.start ?? artifact.excerpts.first?.index ?? 1
            let last = value.end ?? artifact.excerpts.last?.index ?? first
            let excerpts = artifact.excerpts
                .filter { $0.index >= first && $0.index <= last }
                .map(\.content)
            return .sourceInspect(ASKSourceInspectResult(
                sourceID: sourceID.rawValue,
                title: artifact.document.title,
                sourcePath: artifact.sourcePath,
                checksum: artifact.version.checksum,
                contentLength: artifact.version.contentLength,
                start: first,
                end: last,
                excerpts: excerpts
            ))

        case .pendingPatch(let value):
            let patchID = try nonempty(value.patchID, field: "patchID")
            let paths = resolvedPaths(value.workspace)
            let runtime = ASKRuntime(root: paths.vaultURL)
            guard let plan = try runtime.patchPlan(patchID: patchID) else {
                throw ASKDiagnostic(
                    code: .notFound,
                    operation: .query,
                    message: "Patch not found: \(patchID)",
                    context: ["patchID": patchID],
                    recovery: .correctInput
                )
            }
            let snapshot = try runtime.snapshot()
            let status: String
            if snapshot.pendingPatchIDs.contains(patchID) {
                status = "pending"
            } else if snapshot.approvedPatchIDs.contains(patchID) {
                status = "approved"
            } else if snapshot.rejectedPatchIDs.contains(patchID) {
                status = "rejected"
            } else {
                status = "unknown"
            }
            return .pendingPatch(ASKPendingPatchDetailResult(
                patchID: patchID,
                isPending: status == "pending",
                status: status,
                plan: plan
            ))

        case .decisionMemory(let value):
            let paths = resolvedPaths(value.workspace)
            let advice = try await ASKWorkWikiDecisionMemoryAdvisor(
                decisionMemoryRootURL: paths.vaultURL
            ).advise(for: value.frame, budget: value.budget) { state in
                try await ASKDecisionMemoryEvidence.inspect(recordID: state.record.recordID,
                    refs: state.evidenceRefs, indexURL: paths.indexURL)
            }
            return .decisionMemory(ASKDecisionMemoryAdviceResult(
                context: advice.context,
                intervention: advice.intervention
            ))
        }
    }

    private func resolvedPaths(_ selection: ASKWorkspaceSelection) -> ASKPlanContext {
        ASKCommandPlanner.context(for: selection, configuration: configuration)
    }

    private func validateLimit(_ limit: Int) throws {
        guard limit >= 0 else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .query,
                message: "limit must be non-negative",
                context: ["limit": String(limit)],
                recovery: .correctInput
            )
        }
    }

    private func validatePositive(_ value: Int, field: String) throws {
        guard value > 0 else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .query,
                message: "\(field) must be positive",
                context: ["field": field, "value": String(value)],
                recovery: .correctInput
            )
        }
    }

    private func invalidRange(field: String, value: Int) -> ASKDiagnostic {
        ASKDiagnostic(
            code: .invalidRequest,
            operation: .query,
            message: "\(field) must be positive",
            context: ["field": field, "value": String(value)],
            recovery: .correctInput
        )
    }

    private func nonempty(_ value: String, field: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKDiagnostic(
                code: .missingField,
                operation: .query,
                message: "Missing required field: \(field)",
                context: ["field": field],
                recovery: .correctInput
            )
        }
        return value
    }
}
