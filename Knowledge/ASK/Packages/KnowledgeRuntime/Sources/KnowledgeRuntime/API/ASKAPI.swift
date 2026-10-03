@_exported import KnowledgeCore
import Foundation

public protocol ASKKnowledgeReader: Sendable {
    func ensureKnowledgeBase() throws
    func snapshot() throws -> ASKStateSnapshot
    func projectionDocument(slug: String) throws -> ProjectionDocument?
    func search(_ query: String, limit: Int) throws -> SearchResult
    func query(_ question: String, requestedAt: String, fileBackSlug: String?) throws -> QueryResult
    func reviewQueue() throws -> ReviewQueueResult
    func lint() throws -> LintResult
    func pendingPatchPlans() throws -> [KnowledgePatchPlan]
}

public protocol ASKRepresentationStoreAccess: ASKKnowledgeReader {
    func upsertRepresentation(_ record: RepresentationRecord) throws
    func representation(sourceID: String, kind: RepresentationKind) throws -> RepresentationRecord?
    func listRepresentations(sourceID: String) throws -> [RepresentationRecord]
    func lintRepresentations(_ request: RepresentationTrailRequest) throws -> RepresentationLintReport
}

public protocol ASKKnowledgeMaintainer: ASKRepresentationStoreAccess {
    func stage(_ plan: KnowledgePatchPlan) throws
    func importCollected(_ captureManifestPath: URL) throws -> ASKImportedCapture
    func planEvidenceIngest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome
    func planAuthorityRegistration(_ request: RegisterAuthorityRequest, existingRecords: [AuthorityRecord]) throws -> RegisterAuthorityOutcome
    func planProjectionRefresh(_ request: RefreshProjectionRequest) throws -> RefreshProjectionOutcome
    func planProjectionRemoval(slug: String, requestedAt: String, trigger: String) throws -> KnowledgePatchPlan
    func verify(_ plan: KnowledgePatchPlan) throws -> VerificationReport
    func apply(_ plan: KnowledgePatchPlan, _ receipt: PatchDecisionReceipt) throws -> ASKApplySummary
    func rebuild() throws -> ASKRebuildSummary
}

public struct RemoveProjectionCommand: Codable, Sendable, Equatable {
    public struct DecisionContext: Codable, Sendable, Equatable {
        public var requestedAt: String
        public var decidedBy: String
        public var decidedAt: String
        public var reason: String?
        public var trigger: String

        public init(requestedAt: String, decidedBy: String, decidedAt: String, reason: String? = nil, trigger: String = "manual_remove") {
            self.requestedAt = requestedAt
            self.decidedBy = decidedBy
            self.decidedAt = decidedAt
            self.reason = reason
            self.trigger = trigger
        }
    }

    public var slug: String
    public var decision: DecisionContext

    public init(slug: String, decision: DecisionContext) {
        self.slug = slug
        self.decision = decision
    }
}

public struct PromoteSourceCommand: Codable, Sendable, Equatable {
    public struct DecisionContext: Codable, Sendable, Equatable {
        public var requestedAt: String
        public var decidedBy: String
        public var decidedAt: String
        public var trigger: String

        public init(requestedAt: String, decidedBy: String, decidedAt: String, trigger: String = "source_promote") {
            self.requestedAt = requestedAt
            self.decidedBy = decidedBy
            self.decidedAt = decidedAt
            self.trigger = trigger
        }
    }

    public var sourceID: String
    public var slug: String
    public var title: String
    public var bodySeed: String?
    public var decision: DecisionContext

    public init(sourceID: String, slug: String, title: String, bodySeed: String? = nil, decision: DecisionContext) {
        self.sourceID = sourceID
        self.slug = slug
        self.title = title
        self.bodySeed = bodySeed
        self.decision = decision
    }
}

public struct CompileProjectionSetCommand: Codable, Sendable, Equatable {
    public struct DecisionContext: Codable, Sendable, Equatable {
        public var requestedAt: String
        public var decidedBy: String
        public var decidedAt: String
        public var trigger: String

        public init(requestedAt: String, decidedBy: String, decidedAt: String, trigger: String = "source_projection_set_compile") {
            self.requestedAt = requestedAt
            self.decidedBy = decidedBy
            self.decidedAt = decidedAt
            self.trigger = trigger
        }
    }

    public var sourceID: String
    public var sourceSlug: String
    public var sourceTitle: String
    public var sourceBodySeed: String?
    public var related: [WikiProjectionSeed]
    public var decision: DecisionContext

    public init(sourceID: String, sourceSlug: String, sourceTitle: String, sourceBodySeed: String? = nil, related: [WikiProjectionSeed] = [], decision: DecisionContext) {
        self.sourceID = sourceID
        self.sourceSlug = sourceSlug
        self.sourceTitle = sourceTitle
        self.sourceBodySeed = sourceBodySeed
        self.related = related
        self.decision = decision
    }
}

public protocol ASKProjectionMaintainer: ASKKnowledgeMaintainer {
    func removeProjection(_ command: RemoveProjectionCommand) throws -> ASKApplySummary
    func promoteSourceToWiki(_ command: PromoteSourceCommand) throws -> ASKApplySummary
    func compileSourceProjectionSet(_ command: CompileProjectionSetCommand) throws -> ASKApplySummary
}

public extension ASKProjectionMaintainer {
    func removeProjection(
        slug: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        reason: String?,
        trigger: String
    ) throws -> ASKApplySummary
    {
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

    func promoteSourceToWiki(
        sourceID: String,
        slug: String,
        title: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        bodySeed: String?,
        trigger: String
    ) throws -> ASKApplySummary
    {
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

    func compileSourceProjectionSet(
        sourceID: String,
        sourceSlug: String,
        sourceTitle: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        sourceBodySeed: String?,
        related: [WikiProjectionSeed],
        trigger: String
    ) throws -> ASKApplySummary
    {
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
}

public struct ASKRuntimeKnowledgeReader: ASKKnowledgeReader, Sendable {
    private let runtime: ASKRuntime

    public init(root: URL) { self.runtime = ASKRuntime(root: root) }
    public init(rootPath: String) { self.runtime = ASKRuntime(root: rootPath) }
    public init(runtime: ASKRuntime) { self.runtime = runtime }

    public func ensureKnowledgeBase() throws { _ = try runtime.ensureVault() }
    public func snapshot() throws -> ASKStateSnapshot { try runtime.snapshot() }
    public func projectionDocument(slug: String) throws -> ProjectionDocument? { try runtime.projectionDocument(slug: slug) }
    public func search(_ query: String, limit: Int = 8) throws -> SearchResult { try runtime.search(query, limit: limit) }
    public func query(_ question: String, requestedAt: String, fileBackSlug: String? = nil) throws -> QueryResult { try runtime.query(question, requestedAt: requestedAt, fileBackSlug: fileBackSlug) }
    public func reviewQueue() throws -> ReviewQueueResult { try runtime.reviewQueue() }
    public func lint() throws -> LintResult { try runtime.lint() }
    public func pendingPatchPlans() throws -> [KnowledgePatchPlan] { try runtime.pendingPatchPlans() }
}

public struct ASKRuntimeKnowledgeMaintainer: ASKProjectionMaintainer, Sendable {
    private let runtime: ASKRuntime
    private var reader: ASKRuntimeKnowledgeReader { ASKRuntimeKnowledgeReader(runtime: runtime) }

    public init(root: URL) { self.runtime = ASKRuntime(root: root) }
    public init(rootPath: String) { self.runtime = ASKRuntime(root: rootPath) }
    public init(runtime: ASKRuntime) { self.runtime = runtime }

    public func ensureKnowledgeBase() throws { try reader.ensureKnowledgeBase() }
    public func snapshot() throws -> ASKStateSnapshot { try reader.snapshot() }
    public func projectionDocument(slug: String) throws -> ProjectionDocument? { try reader.projectionDocument(slug: slug) }
    public func search(_ query: String, limit: Int = 8) throws -> SearchResult { try reader.search(query, limit: limit) }
    public func query(_ question: String, requestedAt: String, fileBackSlug: String? = nil) throws -> QueryResult { try reader.query(question, requestedAt: requestedAt, fileBackSlug: fileBackSlug) }
    public func reviewQueue() throws -> ReviewQueueResult { try reader.reviewQueue() }
    public func lint() throws -> LintResult { try reader.lint() }
    public func pendingPatchPlans() throws -> [KnowledgePatchPlan] { try reader.pendingPatchPlans() }
    public func upsertRepresentation(_ record: RepresentationRecord) throws { try runtime.upsertRepresentation(record) }
    public func representation(sourceID: String, kind: RepresentationKind) throws -> RepresentationRecord? { try runtime.representation(sourceID: sourceID, kind: kind) }
    public func listRepresentations(sourceID: String) throws -> [RepresentationRecord] { try runtime.listRepresentations(sourceID: sourceID) }
    public func lintRepresentations(_ request: RepresentationTrailRequest) throws -> RepresentationLintReport { try runtime.lintRepresentations(request) }
    public func stage(_ plan: KnowledgePatchPlan) throws { try runtime.stage(plan) }
    public func importCollected(_ captureManifestPath: URL) throws -> ASKImportedCapture { try runtime.importCollected(captureManifestPath) }
    public func planEvidenceIngest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome { try runtime.planEvidenceIngest(request) }
    public func planAuthorityRegistration(_ request: RegisterAuthorityRequest, existingRecords: [AuthorityRecord]) throws -> RegisterAuthorityOutcome { try runtime.planAuthorityRegistration(request, existingRecords: existingRecords) }
    public func planProjectionRefresh(_ request: RefreshProjectionRequest) throws -> RefreshProjectionOutcome { try runtime.planProjectionRefresh(request) }
    public func planProjectionRemoval(slug: String, requestedAt: String, trigger: String = "manual_remove") throws -> KnowledgePatchPlan { try runtime.planProjectionRemoval(slug: slug, requestedAt: requestedAt, trigger: trigger) }
    public func verify(_ plan: KnowledgePatchPlan) throws -> VerificationReport { try runtime.verify(plan) }
    public func apply(_ plan: KnowledgePatchPlan, _ receipt: PatchDecisionReceipt) throws -> ASKApplySummary { try runtime.apply(plan, receipt) }
    public func rebuild() throws -> ASKRebuildSummary { try runtime.rebuild() }
    public func removeProjection(_ command: RemoveProjectionCommand) throws -> ASKApplySummary { try runtime.removeProjection(command) }
    public func promoteSourceToWiki(_ command: PromoteSourceCommand) throws -> ASKApplySummary { try runtime.promoteSourceToWiki(command) }
    public func compileSourceProjectionSet(_ command: CompileProjectionSetCommand) throws -> ASKApplySummary { try runtime.compileSourceProjectionSet(command) }

    public func removeProjection(
        slug: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil,
        trigger: String = "manual_remove"
    ) throws -> ASKApplySummary {
        try runtime.removeProjection(
            slug: slug,
            requestedAt: requestedAt,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason,
            trigger: trigger
        )
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
        try runtime.promoteSourceToWiki(
            sourceID: sourceID,
            slug: slug,
            title: title,
            requestedAt: requestedAt,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            bodySeed: bodySeed,
            trigger: trigger
        )
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
        try runtime.compileSourceProjectionSet(
            sourceID: sourceID,
            sourceSlug: sourceSlug,
            sourceTitle: sourceTitle,
            requestedAt: requestedAt,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            sourceBodySeed: sourceBodySeed,
            related: related,
            trigger: trigger
        )
    }
}
