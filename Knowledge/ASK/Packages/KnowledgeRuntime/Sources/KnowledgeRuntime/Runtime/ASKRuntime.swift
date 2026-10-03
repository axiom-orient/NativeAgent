import Foundation
import KnowledgeCore

public struct ASKRuntime: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var vaultService: ASKRuntimeVaultService {
        ASKRuntimeVaultService(root: root)
    }

    private var storeService: ASKRuntimeStoreService {
        ASKRuntimeStoreService(root: root)
    }

    private var eventService: ASKRuntimeEventService {
        ASKRuntimeEventService(root: root)
    }

    private var archiveService: ASKRuntimeArchiveService {
        ASKRuntimeArchiveService(root: root)
    }

    private var captureService: ASKRuntimeCaptureService {
        ASKRuntimeCaptureService(root: root)
    }

    private var mutationService: ASKRuntimeMutationService {
        ASKRuntimeMutationService(root: root)
    }

    private var projectionService: ASKRuntimeProjectionService {
        ASKRuntimeProjectionService(root: root)
    }

    private var queryService: ASKRuntimeQueryService {
        ASKRuntimeQueryService(root: root)
    }

    private var reviewService: ASKRuntimeReviewService {
        ASKRuntimeReviewService(root: root)
    }

    private var lintService: ASKRuntimeLintService {
        ASKRuntimeLintService(root: root)
    }

    public init(root: String) {
        self.init(root: URL(fileURLWithPath: root, isDirectory: true))
    }

    @discardableResult
    public func ensureVault() throws -> URL {
        try vaultService.ensureVault()
        return root
    }

    public func stage(_ plan: KnowledgePatchPlan) throws {
        try mutationService.stage(plan)
    }

    public func buildReceipt(
        for plan: KnowledgePatchPlan,
        decision: PatchDecision,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil,
        selectedOptionID: String? = nil
    ) throws -> PatchDecisionReceipt {
        try mutationService.buildReceipt(
            for: plan,
            decision: decision,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason,
            selectedOptionID: selectedOptionID
        )
    }

    public func receiptFromChoice(
        for plan: KnowledgePatchPlan,
        choice: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil
    ) throws -> PatchDecisionReceipt {
        try mutationService.receiptFromChoice(
            for: plan,
            choice: choice,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
    }

    public func apply(_ plan: KnowledgePatchPlan, _ receipt: PatchDecisionReceipt) throws -> ASKApplySummary {
        try mutationService.apply(plan, receipt)
    }

    /// Commits several decisions under one materialization. Ingesting many
    /// patches one at a time re-derives the whole vault per patch; this derives
    /// once for the batch. If canonical decisions are already durable when the
    /// derived materialization fails, throws `ASKBatchPostCommitMaterializationError`
    /// with the committed prefix and any decision that stopped the batch.
    public func applyBatch(
        _ decisions: [(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)]
    ) throws -> ASKBatchApplySummary {
        try mutationService.applyBatch(decisions)
    }

    /// Canonical source receipts by ID, read through the journal.
    ///
    /// Consumers used to read `records/sources/<id>.json` straight off disk,
    /// which tied them to a derived file layout the vault owns; the receipts
    /// live in canonical state and are served from here.
    public func sourceReceipts(sourceIDs: [String]) throws -> [String: SourceReceipt] {
        guard !sourceIDs.isEmpty else { return [:] }
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw ASKError.validation("source receipt IDs must be unique")
        }
        let store = try ASKRuntimeStoreService(root: root).loadStore()
        return Dictionary(uniqueKeysWithValues: sourceIDs.compactMap { id in
            store.sources[id].map { (id, $0) }
        })
    }

    /// Derived SQLite files that an exclusive durable-state backup may omit.
    /// Their layout belongs to this runtime; callers must not hardcode it.
    /// This does not acquire a maintenance lock or make an active copy safe.
    public var rebuildableDatabaseURLs: [URL] {
        let mirror = Vault(root: root).mirrorURL()
        return [mirror] + ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: mirror.path + $0) }
    }

    public func rebuild() throws -> ASKRebuildSummary {
        try ASKRebuildSummary(vaultService.rebuild())
    }

    public func storageHealthReport() async throws -> ASKStorageHealthReport {
        try await ASKStorageHealthIntegration.makeVaultStorageHealthRuntime(root: root).healthReport()
    }

    public func rebuildStorage(_ scope: ASKStorageRebuildScope = .search) async throws -> ASKStorageRebuildSummary {
        try await ASKStorageHealthIntegration.makeVaultStorageHealthRuntime(root: root).rebuild(scope)
    }

    public func snapshot() throws -> ASKStateSnapshot {
        try ASKStateSnapshot(storeService.dumpState())
    }

    public func projectionDocument(slug: String) throws -> ProjectionDocument? {
        try projectionService.projectionDocument(slug: slug)
    }

    package func recordEvent(_ entry: OperationLogEntry) throws {
        try eventService.recordEvent(entry)
    }

    /// The complete read scope of a capture, resolved by the import owner.
    /// Hosts must authorize this root, not only the small manifest directory.
    /// This observes layout only and does not import or create files.
    public static func captureStagingRoot(for inputURL: URL) throws -> URL {
        let (_, _, stagingRoot, _) = try Vault.resolveCapturePaths(inputURL)
        return stagingRoot
    }

    public func importCollected(_ captureManifestPath: URL) throws -> ASKImportedCapture {
        try captureService.importCollected(captureManifestPath)
    }

    public func planEvidenceIngest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome {
        try planEvidenceIngestRequest(request)
    }

    public func planAuthorityRegistration(_ request: RegisterAuthorityRequest, existingRecords: [AuthorityRecord]) throws -> RegisterAuthorityOutcome {
        try planAuthorityRegistrationRequest(request, existingRecords: existingRecords)
    }

    public func planProjectionRefresh(_ request: RefreshProjectionRequest) throws -> RefreshProjectionOutcome {
        try projectionService.planProjectionRefresh(request)
    }

    public func promoteSourceToWiki(_ command: PromoteSourceCommand) throws -> ASKApplySummary {
        try projectionService.promoteSourceToWiki(command)
    }

    public func promoteSourceToWiki(
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

    public func compileSourceProjectionSet(_ command: CompileProjectionSetCommand) throws -> ASKApplySummary {
        try projectionService.compileSourceProjectionSet(command)
    }

    public func compileSourceProjectionSet(
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

    public func planProjectionRemoval(slug: String, requestedAt: String, trigger: String = "manual_remove") throws -> KnowledgePatchPlan {
        try projectionService.planProjectionRemoval(slug: slug, requestedAt: requestedAt, trigger: trigger)
    }

    public func removeProjection(_ command: RemoveProjectionCommand) throws -> ASKApplySummary {
        try projectionService.removeProjection(command)
    }

    public func removeProjection(
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

    public func verify(_ plan: KnowledgePatchPlan) throws -> VerificationReport {
        try mutationService.verify(plan)
    }

    public func search(_ query: String, limit: Int = 8) throws -> SearchResult {
        try queryService.search(query, limit: limit)
    }

    package func debugSourceSearchDoc(sourceID: String) throws -> SearchDocRow? {
        try queryService.debugSourceSearchDoc(sourceID: sourceID)
    }

    package func debugMirrorSearch(query: String, limit: Int = 24) throws -> [DebugMirrorCandidate] {
        try queryService.debugMirrorSearch(query: query, limit: limit)
    }

    package func debugQuerySelection(question: String) throws -> DebugQuerySelection {
        try queryService.debugQuerySelection(question: question)
    }

    public func query(_ question: String, requestedAt: String, fileBackSlug: String? = nil) throws -> QueryResult {
        try queryService.query(question, requestedAt: requestedAt, fileBackSlug: fileBackSlug)
    }

    public func reviewQueue() throws -> ReviewQueueResult {
        try reviewService.reviewQueue()
    }

    public func lint() throws -> LintResult {
        try lintService.lint()
    }

    public func exportVault(to outputURL: URL) throws {
        try archiveService.exportArchive(to: outputURL)
    }

    public func importVault(from archiveURL: URL) throws -> ASKStateSnapshot {
        try archiveService.importArchive(from: archiveURL)
    }

    public func importCollectedAndPlan(
        manifestPath: URL,
        domain: String,
        requestedAt: String,
        focusPrompt: String? = nil
    ) throws -> IngestEvidenceOutcome {
        let imported = try importCollected(manifestPath)
        let request = try makeImportedCollectedRequest(
            imported: imported,
            domain: domain,
            requestedAt: requestedAt,
            focusPrompt: focusPrompt
        )
        return try planEvidenceIngestRequest(request)
    }
}
