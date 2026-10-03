import Foundation
import KnowledgeCore

package struct ASKRuntimeVaultService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    @discardableResult
    package func ensureVault() throws -> URL {
        try Vault(root: root).bootstrap()
        return root
    }

    package func stage(_ plan: KnowledgePatchPlan) throws {
        try Vault(root: root).stage(plan)
    }

    package func apply(_ plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) throws -> ApplyResult {
        try Vault(root: root).apply(plan, receipt: receipt)
    }

    package func applyFromCurrentJournal(
        _ buildDecision: (KnowledgeStore) throws -> (plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)
    ) throws -> ApplyResult {
        try Vault(root: root).applyFromCurrentJournal(buildDecision)
    }

    package func rebuild() throws -> RebuildReport {
        try Vault(root: root).rebuild()
    }
}

package struct ASKRuntimeStoreService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func loadStore() throws -> KnowledgeStore {
        try Vault(root: root).loadStoreFromJournal().store
    }

    package func source(for sourceID: String, in store: KnowledgeStore) throws -> SourceReceipt {
        guard let source = store.sources[sourceID] else {
            throw ASKError.notFound("unknown source id `\(sourceID)`")
        }
        return source
    }

    package func dumpState() throws -> VaultDumpState {
        try Vault(root: root).dumpState()
    }
}

package struct ASKRuntimeEventService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func recordEvent(_ entry: OperationLogEntry) throws {
        try Vault(root: root).recordEvent(entry)
    }
}

package struct ASKRuntimeArchiveService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func exportArchive(to outputURL: URL) throws {
        try Vault(root: root).exportArchive(to: outputURL)
    }

    package func importArchive(from archiveURL: URL) throws -> ASKStateSnapshot {
        let vault = Vault(root: root)
        try vault.importArchive(from: archiveURL)
        return try ASKStateSnapshot(vault.dumpState())
    }
}

package struct ASKRuntimeCaptureService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func importCollected(_ manifestURL: URL) throws -> ASKImportedCapture {
        try Vault(root: root).importCollected(manifestURL)
    }
}

package struct ASKRuntimeQueryService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func search(_ query: String, limit: Int) throws -> SearchResult {
        guard limit >= 0 else {
            throw ASKError.validation("search limit must be non-negative")
        }
        let hits = try searchMirrorFirst(root: root.path, query: query, limit: limit)
        return SearchResult(query: query, hits: Array(hits.prefix(limit)))
    }

    package func query(_ question: String, requestedAt: String, fileBackSlug: String?) throws -> QueryResult {
        let hits = try search(question, limit: 12).hits
        let selectedHits = chooseQueryAnswerHits(question: question, hits: hits).selected
        let support = buildQuerySupportMaterial(question: question, selectedHits: selectedHits)

        let fileBackPatch: KnowledgePatchPlan?
        if let fileBackSlug, !selectedHits.isEmpty {
            fileBackPatch = try buildQueryArtifactPatch(
                question: question,
                requestedAt: requestedAt,
                fileBackSlug: fileBackSlug,
                support: support
            )
        } else {
            fileBackPatch = nil
        }

        try ASKRuntimeEventService(root: root).recordEvent(
            OperationLogEntry(
                logID: stableID(prefix: "log", parts: ["query", requestedAt, question]),
                occurredAt: requestedAt,
                opKind: "query",
                summary: "query executed: " + String(question.prefix(96))
            )
        )

        return QueryResult(
            question: question,
            answer: support.answer,
            citations: selectedHits.map {
                QueryCitation(docID: $0.docID, title: $0.title, projectionSlug: $0.projectionSlug)
            },
            results: hits,
            fileBackPatch: fileBackPatch
        )
    }

    package func debugSourceSearchDoc(sourceID: String) throws -> SearchDocRow? {
        try buildDebugSourceSearchDoc(root: root.path, sourceID: sourceID)
    }

    package func debugMirrorSearch(query: String, limit: Int) throws -> [DebugMirrorCandidate] {
        try buildDebugMirrorSearch(root: root.path, query: query, limit: limit)
    }

    package func debugQuerySelection(question: String) throws -> DebugQuerySelection {
        try buildDebugQuerySelection(root: root.path, question: question)
    }
}

package struct ASKRuntimeReviewService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func reviewQueue() throws -> ReviewQueueResult {
        let store = try ASKRuntimeStoreService(root: root).loadStore()
        return ASKRuntimeReviewQueueBuilder.build(from: store)
    }
}

package struct ASKRuntimeLintService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func lint() throws -> LintResult {
        let report = ASKRuntimeLinter.lint(try ASKRuntimeStoreService(root: root).loadStore())
        // Loading state does not digest raw captures, so the explicit report is
        // where a deleted or edited capture surfaces.
        let problems = try Vault(root: root).verifyRawEvidence()
        guard !problems.isEmpty else { return report }
        let findings = report.findings + [
            LintFinding(kind: "raw_evidence_mismatch", severity: "high", count: problems.count, items: problems)
        ]
        return LintResult(findingCount: findings.count, findings: findings)
    }
}

package struct ASKRuntimeMutationService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package func stage(_ plan: KnowledgePatchPlan) throws {
        try ASKRuntimeVaultService(root: root).stage(plan)
    }

    package func applyBatch(
        _ decisions: [(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)]
    ) throws -> ASKBatchApplySummary {
        ASKBatchApplySummary(try Vault(root: root).applyBatch(decisions))
    }

    package func buildReceipt(
        for plan: KnowledgePatchPlan,
        decision: PatchDecision,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil,
        selectedOptionID: String? = nil
    ) throws -> PatchDecisionReceipt {
        try ASKPatchDecisionFactory.makeReceipt(
            for: plan,
            decision: decision,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason,
            selectedOptionID: selectedOptionID
        )
    }

    package func receiptFromChoice(
        for plan: KnowledgePatchPlan,
        choice: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil
    ) throws -> PatchDecisionReceipt {
        try ASKPatchDecisionFactory.makeReceipt(
            for: plan,
            choice: choice,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
    }

    package func apply(_ plan: KnowledgePatchPlan, _ receipt: PatchDecisionReceipt) throws -> ASKApplySummary {
        try ASKApplySummary(ASKRuntimeVaultService(root: root).apply(plan, receipt: receipt))
    }

    package func applyFromCurrentJournal(
        _ buildDecision: (KnowledgeStore) throws -> (plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)
    ) throws -> ASKApplySummary {
        try ASKApplySummary(ASKRuntimeVaultService(root: root).applyFromCurrentJournal(buildDecision))
    }

    package func verify(_ plan: KnowledgePatchPlan) throws -> VerificationReport {
        try verifyPatchPlan(plan)
    }
}

package struct ASKRuntimeProjectionService: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    private var storeService: ASKRuntimeStoreService {
        ASKRuntimeStoreService(root: root)
    }

    private var mutationService: ASKRuntimeMutationService {
        ASKRuntimeMutationService(root: root)
    }

    package func projectionDocument(slug: String) throws -> ProjectionDocument? {
        let store = try storeService.loadStore()
        guard let latest = store.projections[slug]?.last else {
            return nil
        }
        if latest.state == .stale || latest.state == .superseded {
            return nil
        }
        return latest.document
    }

    package func planProjectionRefresh(_ request: RefreshProjectionRequest) throws -> RefreshProjectionOutcome {
        try planProjectionRefreshRequest(request)
    }

    package func promoteSourceToWiki(_ command: PromoteSourceCommand) throws -> ASKApplySummary {
        try mutationService.applyFromCurrentJournal { store in
            let source = try storeService.source(for: command.sourceID, in: store)
            let write = makePromotedSourceProjectionWrite(
                store: store,
                source: source,
                slug: command.slug,
                title: command.title,
                requestedAt: command.decision.requestedAt,
                bodySeed: command.bodySeed
            )
            return try approvedRefreshDecision(
                writes: [write],
                requestedAt: command.decision.requestedAt,
                trigger: command.decision.trigger,
                decidedBy: command.decision.decidedBy,
                decidedAt: command.decision.decidedAt,
                reason: "promote source \(command.sourceID) to wiki `\(command.slug)`"
            )
        }
    }

    package func promoteSourceToWiki(
        sourceID: String,
        slug: String,
        title: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        bodySeed: String? = nil,
        trigger: String = "source_promote"
    ) throws -> ASKApplySummary {
        try promoteSourceToWiki(
            PromoteSourceCommand(
                sourceID: sourceID,
                slug: slug,
                title: title,
                bodySeed: bodySeed,
                decision: PromoteSourceCommand.DecisionContext(
                    requestedAt: requestedAt,
                    decidedBy: decidedBy,
                    decidedAt: decidedAt,
                    trigger: trigger
                )
            )
        )
    }

    package func compileSourceProjectionSet(_ command: CompileProjectionSetCommand) throws -> ASKApplySummary {
        try mutationService.applyFromCurrentJournal { store in
            let source = try storeService.source(for: command.sourceID, in: store)

            let sourceMetadata = ProjectionMetadata(
                projectionKind: .sourceSummary,
                projectionSpace: .wiki,
                subjectKind: "source",
                subjectID: command.sourceID,
                authorityIDs: [],
                sourceIDs: [command.sourceID],
                claimIDs: [],
                historical: false,
                approvalRequired: false
            )
            let canonicalSourceSlug = canonicalProjectionSlug(slug: command.sourceSlug, metadata: sourceMetadata)
            let extractedRelated = command.related.isEmpty
                ? try automaticProjectionSeeds(store: store, source: source)
                : command.related
            let companions = try buildProjectionSetCompanionInfo(sourceID: command.sourceID, seeds: extractedRelated)
            let sourceWrite = makePromotedSourceProjectionWrite(
                store: store,
                source: source,
                slug: canonicalSourceSlug,
                title: command.sourceTitle,
                requestedAt: command.decision.requestedAt,
                bodySeed: command.sourceBodySeed,
                relatedPages: companions.map { ($0.slug, $0.title) }
            )
            let companionWrites = companions.map { info in
                makeCompiledProjectionWrite(
                    store: store,
                    source: source,
                    sourceSlug: canonicalSourceSlug,
                    sourceTitle: command.sourceTitle,
                    requestedAt: command.decision.requestedAt,
                    seed: info.seed,
                    canonicalSlug: info.slug,
                    relatedPages: [(canonicalSourceSlug, command.sourceTitle)] + companions.filter { $0.slug != info.slug }.map { ($0.slug, $0.title) }
                )
            }

            return try approvedRefreshDecision(
                writes: [sourceWrite] + companionWrites,
                requestedAt: command.decision.requestedAt,
                trigger: command.decision.trigger,
                decidedBy: command.decision.decidedBy,
                decidedAt: command.decision.decidedAt,
                reason: "compile source projection set for \(command.sourceID)"
            )
        }
    }

    package func compileSourceProjectionSet(
        sourceID: String,
        sourceSlug: String,
        sourceTitle: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        sourceBodySeed: String? = nil,
        related: [WikiProjectionSeed] = [],
        trigger: String = "source_projection_set_compile"
    ) throws -> ASKApplySummary {
        try compileSourceProjectionSet(
            CompileProjectionSetCommand(
                sourceID: sourceID,
                sourceSlug: sourceSlug,
                sourceTitle: sourceTitle,
                sourceBodySeed: sourceBodySeed,
                related: related,
                decision: CompileProjectionSetCommand.DecisionContext(
                    requestedAt: requestedAt,
                    decidedBy: decidedBy,
                    decidedAt: decidedAt,
                    trigger: trigger
                )
            )
        )
    }

    package func planProjectionRemoval(slug: String, requestedAt: String, trigger: String = "manual_remove") throws -> KnowledgePatchPlan {
        let store = try storeService.loadStore()
        return try projectionRemovalPlan(slug: slug, requestedAt: requestedAt, trigger: trigger, store: store)
    }

    package func removeProjection(_ command: RemoveProjectionCommand) throws -> ASKApplySummary {
        try mutationService.applyFromCurrentJournal { store in
            let plan = try projectionRemovalPlan(
                slug: command.slug,
                requestedAt: command.decision.requestedAt,
                trigger: command.decision.trigger,
                store: store
            )
            let receipt = try mutationService.buildReceipt(
                for: plan,
                decision: .approved,
                decidedBy: command.decision.decidedBy,
                decidedAt: command.decision.decidedAt,
                reason: command.decision.reason ?? "remove projection \(command.slug)"
            )
            return (plan, receipt)
        }
    }

    package func removeProjection(
        slug: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil,
        trigger: String = "manual_remove"
    ) throws -> ASKApplySummary {
        try removeProjection(
            RemoveProjectionCommand(
                slug: slug,
                decision: RemoveProjectionCommand.DecisionContext(
                    requestedAt: requestedAt,
                    decidedBy: decidedBy,
                    decidedAt: decidedAt,
                    reason: reason,
                    trigger: trigger
                )
            )
        )
    }

    private func approvedRefreshDecision(
        writes: [ProjectionWrite],
        requestedAt: String,
        trigger: String,
        decidedBy: String,
        decidedAt: String,
        reason: String
    ) throws -> (plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) {
        let request = RefreshProjectionRequest(
            version: refreshProjectionRequestVersion,
            requestedAt: requestedAt,
            trigger: trigger,
            proposedWrites: writes
        )
        let plan = try planProjectionRefreshRequest(request).patch
        let receipt = try mutationService.buildReceipt(
            for: plan,
            decision: .approved,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
        return (plan, receipt)
    }

    private func projectionRemovalPlan(
        slug: String,
        requestedAt: String,
        trigger: String,
        store: KnowledgeStore
    ) throws -> KnowledgePatchPlan {
        guard let latest = store.projections[slug]?.last else {
            throw ASKError.notFound("unknown projection slug `\(slug)`")
        }
        if latest.state == .stale || latest.state == .superseded {
            throw ASKError.validation("projection `\(slug)` is already hidden")
        }
        let plan = makeProjectionRemovalPlan(latest: latest, slug: slug, requestedAt: requestedAt, trigger: trigger)
        try plan.validate()
        return plan
    }
}
