import Foundation
import KnowledgeCore
import EvidenceIndex

func askCanonicalFileURL(_ url: URL) -> URL {
    guard url.isFileURL else { return url }
    // Token identity and command-plan identity must not change when a previously
    // missing route becomes materialized. Foundation's standardizedFileURL may
    // resolve an alias such as /private/var differently once an ancestor exists,
    // so canonicalize path syntax lexically here. Symlink-aware containment remains
    // an effect-boundary check in ASKManagedRouteContainment.
    return URL(fileURLWithPath: askLexicallyStandardizedPath(url.path), isDirectory: false)
}

private func askLexicallyStandardizedPath(_ path: String) -> String {
    let isAbsolute = path.hasPrefix("/")
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".":
            continue
        case "..":
            if let last = components.last, last != ".." {
                components.removeLast()
            } else if !isAbsolute {
                components.append(component)
            }
        default:
            components.append(component)
        }
    }

    let body = components.map(String.init).joined(separator: "/")
    if isAbsolute { return body.isEmpty ? "/" : "/" + body }
    return body.isEmpty ? "." : body
}

public struct ASKWorkspaceSelection: Codable, Equatable, Sendable {
    public let workspaceURL: URL?
    public let vaultURL: URL?
    public let indexURL: URL?
    public let productWorkspaceURL: URL?

    public init(
        workspaceURL: URL? = nil,
        vaultURL: URL? = nil,
        indexURL: URL? = nil,
        productWorkspaceURL: URL? = nil
    ) {
        self.workspaceURL = workspaceURL.map(askCanonicalFileURL)
        self.vaultURL = vaultURL.map(askCanonicalFileURL)
        self.indexURL = indexURL.map(askCanonicalFileURL)
        self.productWorkspaceURL = productWorkspaceURL.map(askCanonicalFileURL)
    }
}

public struct ASKQuickStartCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let requestedAt: String
    public let decidedBy: String
    public let reason: String
    public let resetExistingWorkspace: Bool

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        requestedAt: String,
        decidedBy: String = "ask",
        reason: String = "ASK quick-start approval",
        resetExistingWorkspace: Bool = false
    ) {
        self.workspace = workspace
        self.requestedAt = requestedAt
        self.decidedBy = decidedBy
        self.reason = reason
        self.resetExistingWorkspace = resetExistingWorkspace
    }
}

public struct ASKIndexWorkspaceCommand: Codable, Equatable, Sendable {
    public let sourceRootURL: URL
    public let workspace: ASKWorkspaceSelection

    public init(
        sourceRootURL: URL,
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection()
    ) {
        self.sourceRootURL = askCanonicalFileURL(sourceRootURL)
        self.workspace = workspace
    }
}

public struct ASKImportWorkspaceCommand: Codable, Equatable, Sendable {
    public let sourceRootURL: URL
    public let workspace: ASKWorkspaceSelection
    public let title: String
    public let queryText: String
    public let requestedAt: String
    public let decidedBy: String
    public let reason: String
    public let slug: String?
    public let subjectID: String?
    public let maxEvidenceBytes: Int
    public let includeStaleEvidence: Bool
    public let resetExistingWorkspace: Bool

    public init(
        sourceRootURL: URL,
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        title: String,
        queryText: String,
        requestedAt: String,
        decidedBy: String = "ask",
        reason: String = "ASK workspace import approval",
        slug: String? = nil,
        subjectID: String? = nil,
        maxEvidenceBytes: Int = 262_144,
        includeStaleEvidence: Bool = false,
        resetExistingWorkspace: Bool = false
    ) {
        self.sourceRootURL = askCanonicalFileURL(sourceRootURL)
        self.workspace = workspace
        self.title = title
        self.queryText = queryText
        self.requestedAt = requestedAt
        self.decidedBy = decidedBy
        self.reason = reason
        self.slug = slug
        self.subjectID = subjectID
        self.maxEvidenceBytes = maxEvidenceBytes
        self.includeStaleEvidence = includeStaleEvidence
        self.resetExistingWorkspace = resetExistingWorkspace
    }
}

public struct ASKStageReportCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let title: String
    public let queryText: String
    public let requestedAt: String
    public let slug: String?
    public let subjectID: String?
    public let maxEvidenceBytes: Int
    public let includeStaleEvidence: Bool

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        title: String,
        queryText: String,
        requestedAt: String,
        slug: String? = nil,
        subjectID: String? = nil,
        maxEvidenceBytes: Int = 262_144,
        includeStaleEvidence: Bool = false
    ) {
        self.workspace = workspace
        self.title = title
        self.queryText = queryText
        self.requestedAt = requestedAt
        self.slug = slug
        self.subjectID = subjectID
        self.maxEvidenceBytes = maxEvidenceBytes
        self.includeStaleEvidence = includeStaleEvidence
    }
}

public struct ASKCloseDayCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let date: String
    public let queryText: String?
    public let requestedAt: String
    public let slug: String?
    public let subjectID: String?
    public let maxEvidenceBytes: Int
    public let includeStaleEvidence: Bool

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        date: String,
        queryText: String? = nil,
        requestedAt: String,
        slug: String? = nil,
        subjectID: String? = nil,
        maxEvidenceBytes: Int = 262_144,
        includeStaleEvidence: Bool = false
    ) {
        self.workspace = workspace
        self.date = date
        self.queryText = queryText
        self.requestedAt = requestedAt
        self.slug = slug
        self.subjectID = subjectID
        self.maxEvidenceBytes = maxEvidenceBytes
        self.includeStaleEvidence = includeStaleEvidence
    }
}

public struct ASKImportCaptureCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let captureManifestURL: URL
    public let domain: String
    public let requestedAt: String
    public let focusPrompt: String?

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        captureManifestURL: URL,
        domain: String,
        requestedAt: String,
        focusPrompt: String? = nil
    ) {
        self.workspace = workspace
        self.captureManifestURL = askCanonicalFileURL(captureManifestURL)
        self.domain = domain
        self.requestedAt = requestedAt
        self.focusPrompt = focusPrompt
    }
}

public enum ASKPatchDecision: String, Codable, Equatable, Sendable {
    case approved
    case rejected
}

public struct ASKDecidePatchCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let patchID: String
    public let decision: ASKPatchDecision
    public let decidedBy: String
    public let decidedAt: String
    public let reason: String
    public let requireFreshEvidence: Bool

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        patchID: String,
        decision: ASKPatchDecision,
        decidedBy: String = "ask",
        decidedAt: String,
        reason: String,
        requireFreshEvidence: Bool = true
    ) {
        self.workspace = workspace
        self.patchID = patchID
        self.decision = decision
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.reason = reason
        self.requireFreshEvidence = requireFreshEvidence
    }
}

public struct ASKRepairPresentationCommand: Codable, Equatable, Sendable {
    public let token: ASKPresentationRepairToken
    public let requestedAt: String

    public init(token: ASKPresentationRepairToken, requestedAt: String) {
        self.token = token
        self.requestedAt = requestedAt
    }
}

/// Rebuilds every derived knowledge artifact from the canonical journal.
/// This is the recovery primitive for a commit that reached the journal but
/// failed while materializing Markdown, SQLite, or generation metadata.
public struct ASKRebuildKnowledgeCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let requestedAt: String

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        requestedAt: String
    ) {
        self.workspace = workspace
        self.requestedAt = requestedAt
    }
}

/// Explicitly records an observed or proposed decision-memory fact. Promotion
/// and verification remain separate immutable transitions.
public struct ASKRecordDecisionMemoryCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let record: MemoryRecord

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), record: MemoryRecord) {
        self.workspace = workspace
        self.record = record
    }
}

/// Appends many immutable STIM decision-memory records under one journal pass.
public struct ASKRecordDecisionMemoriesCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let records: [MemoryRecord]

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), records: [MemoryRecord]) {
        self.workspace = workspace
        self.records = records
    }
}

/// Explicitly appends a decision-memory verification, promotion, supersession,
/// retraction, or expiry transition. It does not execute a work action.
public struct ASKTransitionDecisionMemoryCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let transition: MemoryTransition

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), transition: MemoryTransition) {
        self.workspace = workspace
        self.transition = transition
    }
}

/// Rebuilds generated decision-memory Markdown from canonical JSON facts.
public struct ASKConsolidateDecisionMemoryCommand: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let asOf: String

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), asOf: String) {
        self.workspace = workspace
        self.asOf = asOf
    }
}

/// Canonical write contract. Irrelevant fields cannot coexist across cases.
public enum ASKCommand: Codable, Equatable, Sendable {
    case quickStart(ASKQuickStartCommand)
    case indexWorkspace(ASKIndexWorkspaceCommand)
    case importWorkspace(ASKImportWorkspaceCommand)
    case stageReport(ASKStageReportCommand)
    case closeDay(ASKCloseDayCommand)
    case importCapture(ASKImportCaptureCommand)
    case decidePatch(ASKDecidePatchCommand)
    case repairPresentation(ASKRepairPresentationCommand)
    case rebuildKnowledge(ASKRebuildKnowledgeCommand)
    case recordDecisionMemory(ASKRecordDecisionMemoryCommand)
    case recordDecisionMemories(ASKRecordDecisionMemoriesCommand)
    case transitionDecisionMemory(ASKTransitionDecisionMemoryCommand)
    case consolidateDecisionMemory(ASKConsolidateDecisionMemoryCommand)
}

/// Tells an external executor whether it may repeat an interrupted application.
///
/// Planning and dry-run are always effect-free. This policy describes only the
/// effecting `ASKClient.apply(_:)` call.
public enum ASKReplayPolicy: String, Codable, Equatable, Sendable {
    case replaySafe = "replay_safe"
    case requiresResolution = "requires_resolution"
}

public extension ASKCommand {
    var replayPolicy: ASKReplayPolicy {
        switch self {
        case .indexWorkspace, .repairPresentation, .rebuildKnowledge:
            return .replaySafe
        case .quickStart, .importWorkspace, .stageReport, .closeDay, .importCapture, .decidePatch,
             .recordDecisionMemory, .recordDecisionMemories, .transitionDecisionMemory, .consolidateDecisionMemory:
            return .requiresResolution
        }
    }
}

public struct ASKPlanContext: Codable, Equatable, Sendable {
    public let workspaceURL: URL
    public let vaultURL: URL
    public let indexURL: URL
    public let productWorkspaceURL: URL
    public let sourceRootURL: URL?
    public let captureManifestURL: URL?

    public init(
        workspaceURL: URL,
        vaultURL: URL,
        indexURL: URL,
        productWorkspaceURL: URL,
        sourceRootURL: URL? = nil,
        captureManifestURL: URL? = nil
    ) {
        self.workspaceURL = askCanonicalFileURL(workspaceURL)
        self.vaultURL = askCanonicalFileURL(vaultURL)
        self.indexURL = askCanonicalFileURL(indexURL)
        self.productWorkspaceURL = askCanonicalFileURL(productWorkspaceURL)
        self.sourceRootURL = sourceRootURL.map(askCanonicalFileURL)
        self.captureManifestURL = captureManifestURL.map(askCanonicalFileURL)
    }
}

public struct ASKCommandPlan: Codable, Equatable, Sendable {
    public let actionID: String
    public let command: ASKCommand
    public let context: ASKPlanContext
    public let summary: String

    public init(actionID: String, command: ASKCommand, context: ASKPlanContext, summary: String) {
        self.actionID = actionID
        self.command = command
        self.context = context
        self.summary = summary
    }
}

public struct ASKDryRunResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let context: ASKPlanContext
    public let summary: String
}

public struct ASKSourceIndexResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let sourceRootURL: URL
    public let indexURL: URL
    public let indexedSourceIDs: [String]
    public let indexedPaths: [String]
    public let skippedCount: Int
}

public struct ASKWorkspaceApplyResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let workspaceURL: URL
    public let sourceRootURL: URL
    public let indexURL: URL
    public let vaultURL: URL
    public let publishedProjectionURL: URL?
    public let indexedCount: Int
    public let skippedCount: Int
    public let evidenceHitCount: Int
    public let remainingPendingPatchCount: Int
    public let patchID: String
    public let projectionSlug: String
    public let title: String
    public let decision: ASKPatchDecision
    public let preview: String
}

public struct ASKReportStagedResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let patchID: String
    public let projectionSlug: String
    public let evidenceHitCount: Int
}

public struct ASKCloseDayStagedResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let patchID: String
    public let projectionSlug: String
    public let evidenceHitCount: Int
    public let doneCount: Int
    public let blockerCount: Int
}

public struct ASKCaptureStagedResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let patchID: String
    public let sourceID: String
    public let rawURL: URL
}

public enum ASKStagedPatchResult: Codable, Equatable, Sendable {
    case report(ASKReportStagedResult)
    case closeDay(ASKCloseDayStagedResult)
    case capture(ASKCaptureStagedResult)
}

public struct ASKPatchDecisionResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let patchID: String
    public let decision: ASKPatchDecision
    public let remainingPendingPatchCount: Int
}

public struct ASKPresentationRepairToken: Codable, Equatable, Sendable {
    public let id: String
    public let actionID: String
    public let knowledgeRootURL: URL
    public let productWorkspaceURL: URL
    public let projectionSlugs: [String]
    public let createdAt: String

    public init(
        id: String,
        actionID: String,
        knowledgeRootURL: URL,
        productWorkspaceURL: URL,
        projectionSlugs: [String],
        createdAt: String
    ) {
        self.id = id
        self.actionID = actionID
        self.knowledgeRootURL = askCanonicalFileURL(knowledgeRootURL)
        self.productWorkspaceURL = askCanonicalFileURL(productWorkspaceURL)
        self.projectionSlugs = Array(Set(projectionSlugs)).sorted()
        self.createdAt = createdAt
    }
}

public struct ASKPresentationRepairResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let token: ASKPresentationRepairToken
    public let materializedProjectionCount: Int
    public let alreadyCompleted: Bool
}

public struct ASKKnowledgeRebuildResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let approvedPatchIDs: [String]
    public let rejectedPatchIDs: [String]
    public let pendingPatchIDs: [String]
    public let mirrorCounts: [String: Int]
}

/// Canonical state is already committed. Only its derived materialization
/// failed, so callers must not retry the original mutation blindly.
public struct ASKCommittedRecoveryResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let patchID: String
    public let decision: ASKPatchDecision
    public let diagnostic: ASKDiagnostic
}

public enum ASKDecisionMemoryMutationKind: String, Codable, Equatable, Sendable {
    case record
    case transition
    case consolidate
}

public struct ASKDecisionMemoryMutationResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let kind: ASKDecisionMemoryMutationKind
    public let generation: String
    public let recordCount: Int
    public let transitionCount: Int
    public let materializedFiles: [String]

    public init(
        actionID: String,
        kind: ASKDecisionMemoryMutationKind,
        generation: String,
        recordCount: Int,
        transitionCount: Int,
        materializedFiles: [String] = []
    ) {
        self.actionID = actionID
        self.kind = kind
        self.generation = generation
        self.recordCount = recordCount
        self.transitionCount = transitionCount
        self.materializedFiles = materializedFiles
    }
}

public enum ASKCommittedValue: Codable, Equatable, Sendable {
    case workspace(ASKWorkspaceApplyResult)
    case decision(ASKPatchDecisionResult)
}

public struct ASKRepairRequirement: Codable, Equatable, Sendable {
    public let token: ASKPresentationRepairToken
    public let diagnostic: ASKDiagnostic
}

public enum ASKApplyOutcome: Codable, Equatable, Sendable {
    case sourcesIndexed(ASKSourceIndexResult)
    case workspaceApplied(ASKWorkspaceApplyResult)
    case staged(ASKStagedPatchResult)
    case decided(ASKPatchDecisionResult)
    case presentationRepaired(ASKPresentationRepairResult)
    case knowledgeRebuilt(ASKKnowledgeRebuildResult)
    case decisionMemory(ASKDecisionMemoryMutationResult)
    case committedWithRepairRequired(ASKCommittedValue, ASKRepairRequirement)
    case committedWithRecoveryRequired(ASKCommittedRecoveryResult)
}

public struct ASKEvidenceSearchQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let text: String
    public let limit: Int
    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), text: String, limit: Int = 100) {
        self.workspace = workspace; self.text = text; self.limit = limit
    }
}

public struct ASKKnowledgeSearchQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let text: String
    public let limit: Int
    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), text: String, limit: Int = 100) {
        self.workspace = workspace; self.text = text; self.limit = limit
    }
}

public struct ASKEvidenceRetrieveQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let question: String
    public let sourceIDs: [String]
    public let maxSources: Int
    public let maxTreeDepth: Int
    public let maxVisitedNodes: Int
    public let maxRawEvidenceTokens: Int

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        question: String,
        sourceIDs: [String] = [],
        maxSources: Int = 64,
        maxTreeDepth: Int = 8,
        maxVisitedNodes: Int = 128,
        maxRawEvidenceTokens: Int = 32_768
    ) {
        self.workspace = workspace
        self.question = question
        self.sourceIDs = sourceIDs
        self.maxSources = maxSources
        self.maxTreeDepth = maxTreeDepth
        self.maxVisitedNodes = maxVisitedNodes
        self.maxRawEvidenceTokens = maxRawEvidenceTokens
    }
}

public struct ASKProjectionQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let slug: String
    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), slug: String) {
        self.workspace = workspace; self.slug = slug
    }
}

public struct ASKMarkdownPageQuery: Codable, Equatable, Sendable {
    public let markdown: String
    public let title: String?
    public let documentID: String
    public let sourceID: String
    public init(markdown: String, title: String? = nil, documentID: String = "ask-markdown", sourceID: String = "ask-source") {
        self.markdown = markdown; self.title = title; self.documentID = documentID; self.sourceID = sourceID
    }
}

public struct ASKReadingContextQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let projectionSlug: String
    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), projectionSlug: String) {
        self.workspace = workspace; self.projectionSlug = projectionSlug
    }
}

public struct ASKStorageHealthQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection()) { self.workspace = workspace }
}

public struct ASKPendingWorkQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection()) {
        self.workspace = workspace
    }
}

public struct ASKSourceInspectQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let sourceID: String
    /// Omit for the active version. When supplied, never fall back to current.
    public let sourceVersionChecksum: String?
    public let start: Int?
    public let end: Int?

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        sourceID: String,
        start: Int? = nil,
        end: Int? = nil,
        sourceVersionChecksum: String? = nil
    ) {
        self.workspace = workspace
        self.sourceID = sourceID
        self.sourceVersionChecksum = sourceVersionChecksum
        self.start = start
        self.end = end
    }
}

public struct ASKPendingPatchQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let patchID: String

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        patchID: String
    ) {
        self.workspace = workspace
        self.patchID = patchID
    }
}

/// Read-only request for deterministic decision-memory context. The caller
/// supplies the scope; ASK never infers it from embeddings or model output.
public struct ASKDecisionMemoryQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let frame: TaskFrame
    public let budget: ContextBudget

    public init(
        workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(),
        frame: TaskFrame,
        budget: ContextBudget = ContextBudget()
    ) {
        self.workspace = workspace
        self.frame = frame
        self.budget = budget
    }
}

public struct ASKGroundedEvidenceQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let text: String
    public let limit: Int
    public let maxBytes: Int
    public let freshnessRequirement: ASKEvidenceFreshnessRequirement

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), text: String,
                limit: Int = 20, maxBytes: Int = ASKEvidencePackRequest.defaultMaxBytes,
                freshnessRequirement: ASKEvidenceFreshnessRequirement = .currentSource) {
        self.workspace = workspace
        self.text = text
        self.limit = limit
        self.maxBytes = maxBytes
        self.freshnessRequirement = freshnessRequirement
    }
}

public struct ASKResolveEvidenceQuery: Codable, Equatable, Sendable {
    public let workspace: ASKWorkspaceSelection
    public let reference: ASKEvidenceReference
    public let freshnessRequirement: ASKEvidenceFreshnessRequirement

    public init(workspace: ASKWorkspaceSelection = ASKWorkspaceSelection(), reference: ASKEvidenceReference,
                freshnessRequirement: ASKEvidenceFreshnessRequirement = .currentSource) {
        self.workspace = workspace
        self.reference = reference
        self.freshnessRequirement = freshnessRequirement
    }
}

public enum ASKQuery: Codable, Equatable, Sendable {
    case groundedEvidence(ASKGroundedEvidenceQuery)
    case resolveEvidence(ASKResolveEvidenceQuery)
    case searchEvidence(ASKEvidenceSearchQuery)
    case searchKnowledge(ASKKnowledgeSearchQuery)
    case retrieveEvidence(ASKEvidenceRetrieveQuery)
    case projection(ASKProjectionQuery)
    case markdownPage(ASKMarkdownPageQuery)
    case readingContext(ASKReadingContextQuery)
    case storageHealth(ASKStorageHealthQuery)
    case pendingWork(ASKPendingWorkQuery)
    case sourceInspect(ASKSourceInspectQuery)
    case pendingPatch(ASKPendingPatchQuery)
    case decisionMemory(ASKDecisionMemoryQuery)
}

public extension ASKQuery {
    var replayPolicy: ASKReplayPolicy { .replaySafe }
}

public struct ASKSearchItem: Codable, Equatable, Sendable {
    public let id: String?
    public let sourceID: String?
    public let nodeID: String?
    public let revision: String?
    public let rangeStart: Int?
    public let rangeEnd: Int?
    public let freshness: String?
    public let projectionSlug: String?
    public let title: String
    public let excerpt: String

    public init(
        id: String? = nil,
        sourceID: String? = nil,
        nodeID: String? = nil,
        revision: String? = nil,
        rangeStart: Int? = nil,
        rangeEnd: Int? = nil,
        freshness: String? = nil,
        projectionSlug: String? = nil,
        title: String,
        excerpt: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.revision = revision
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.freshness = freshness
        self.projectionSlug = projectionSlug
        self.title = title
        self.excerpt = excerpt
    }
}

public struct ASKSearchResult: Codable, Equatable, Sendable {
    public let items: [ASKSearchItem]
}

public struct ASKProjectionResult: Codable, Equatable, Sendable {
    public let slug: String
    public let title: String
    public let body: String
}

public struct ASKMarkdownPageResult: Codable, Equatable, Sendable {
    public let title: String?
    public let sectionCount: Int
    public let blockCount: Int
}

public struct ASKReadingContextResult: Codable, Equatable, Sendable {
    public let projectionSlug: String
    public let title: String
    public let bundleRootURL: URL
    public let sourceCatalogCount: Int
    public let catalogEntryCount: Int
    public let resolvedBacklinkCount: Int
    public let unresolvedBacklinkCount: Int
}

public struct ASKStorageComponentStatus: Codable, Equatable, Sendable {
    public let component: String
    public let state: String
}

public struct ASKStorageHealthResult: Codable, Equatable, Sendable {
    public let isHealthy: Bool
    public let components: [ASKStorageComponentStatus]
}

public struct ASKPendingPatchItem: Codable, Equatable, Sendable, Identifiable {
    public let patchID: String
    public let kind: String
    public let generatedAt: String
    public let title: String?

    public var id: String { patchID }

    public init(patchID: String, kind: String, generatedAt: String, title: String?) {
        self.patchID = patchID
        self.kind = kind
        self.generatedAt = generatedAt
        self.title = title
    }
}

public struct ASKPendingWorkResult: Codable, Equatable, Sendable {
    public let patches: [ASKPendingPatchItem]
    public let presentationRepairs: [ASKPresentationRepairToken]

    public init(
        patches: [ASKPendingPatchItem],
        presentationRepairs: [ASKPresentationRepairToken]
    ) {
        self.patches = patches
        self.presentationRepairs = presentationRepairs
    }
}

public struct ASKRAGEvidenceItem: Codable, Equatable, Sendable {
    public let sourceID: String
    public let sourceVersionChecksum: String
    public let nodeID: String
    public let rangeStart: Int
    public let rangeEnd: Int
    public let excerptIndex: Int
    public let content: String
}

public struct ASKEvidenceRetrieveResult: Codable, Equatable, Sendable {
    public let answerability: String
    public let evidence: [ASKRAGEvidenceItem]
    public let selectedSourceIDs: [String]
    public let visitedNodeIDs: [String]
    public let rawEvidenceTokens: Int
    public let diagnostics: [String]
}

public struct ASKSourceInspectResult: Codable, Equatable, Sendable {
    public let sourceID: String
    public let title: String
    public let sourcePath: String?
    public let checksum: String
    public let contentLength: Int
    public let start: Int
    public let end: Int
    public let excerpts: [String]
}

public struct ASKPendingPatchDetailResult: Codable, Equatable, Sendable {
    public let patchID: String
    public let isPending: Bool
    /// `pending`, `approved`, or `rejected`. Additive observation for response-loss recovery.
    public let status: String
    public let plan: KnowledgePatchPlan

    public init(patchID: String, isPending: Bool, status: String, plan: KnowledgePatchPlan) {
        self.patchID = patchID
        self.isPending = isPending
        self.status = status
        self.plan = plan
    }
}

/// The root facade returns only compiled context and a non-acting policy. An
/// execution workflow must explicitly decide whether it pauses or proceeds.
public struct ASKDecisionMemoryAdviceResult: Codable, Equatable, Sendable {
    public let context: ContextBundle
    public let intervention: InterventionDecision

    public init(context: ContextBundle, intervention: InterventionDecision) {
        self.context = context
        self.intervention = intervention
    }
}

public enum ASKQueryResult: Codable, Equatable, Sendable {
    case groundedEvidence(ASKEvidenceGroundedPack)
    case resolvedEvidence(ASKEvidenceResolution)
    case evidenceSearch(ASKSearchResult)
    case knowledgeSearch(ASKSearchResult)
    case evidenceRetrieved(ASKEvidenceRetrieveResult)
    case projection(ASKProjectionResult)
    case markdownPage(ASKMarkdownPageResult)
    case readingContext(ASKReadingContextResult)
    case storageHealth(ASKStorageHealthResult)
    case pendingWork(ASKPendingWorkResult)
    case sourceInspect(ASKSourceInspectResult)
    case pendingPatch(ASKPendingPatchDetailResult)
    case decisionMemory(ASKDecisionMemoryAdviceResult)
}
