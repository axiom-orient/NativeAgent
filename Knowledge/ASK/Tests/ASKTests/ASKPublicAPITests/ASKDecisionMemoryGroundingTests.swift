import Foundation
import KnowledgeCore
import EvidenceIndex
import WorkWiki
import Testing
@testable import ASK

@Test func sourceClaimCannotBecomeVerifiedWithoutExactAnchor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-grounding-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ASKClient(configuration: ASKConfiguration(workspaceURL: root))
    let record = MemoryRecord(recordID: "fact", kind: .observation,
        subject: MemorySubject(kind: "note", subjectID: "contract"),
        scope: MemoryScope(workspaceID: "test"), taskID: "task",
        statement: "The final amount is 48271 won.", createdAt: "2026-09-12T00:00:00Z")
    _ = try await client.apply(try client.plan(.recordDecisionMemory(ASKRecordDecisionMemoryCommand(record: record))))
    let transition = MemoryTransition(transitionID: "verify", recordID: "fact", kind: .verify,
        occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "source checked",
        evidenceRefs: [MemoryEvidenceRef(evidenceID: "forged", kind: .pageIndexAnchor,
            freshness: .fresh, sourceID: "nonexistent", nodeID: "nonexistent")])
    do {
        _ = try await client.apply(try client.plan(.transitionDecisionMemory(ASKTransitionDecisionMemoryCommand(transition: transition))))
        Issue.record("Caller-declared freshness must not verify an unresolvable source")
    } catch let diagnostic as ASKDiagnostic {
        #expect(diagnostic.code == .invalidRequest)
        #expect(diagnostic.operation == .plan)
        #expect(diagnostic.message.contains("exact_anchor"))
    }
}

private struct GroundedMemoryFixture {
    let root: URL
    let sourceFile: URL
    let client: ASKClient
    let reference: ASKEvidenceReference
    let frame = TaskFrame(taskID: "task", workspaceID: "test", riskTags: ["irreversible"], requestedAt: "2026-09-12T01:00:00Z")

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grounded-memory-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("confirmed.md")
        try Data("# Contract\n\nThe final amount is 48,271 won. VAT is separate.\n".utf8).write(to: file)
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: root.appendingPathComponent("workspace")))
        _ = try await client.apply(try client.plan(.indexWorkspace(ASKIndexWorkspaceCommand(sourceRootURL: source))))
        guard case .groundedEvidence(let pack) = try await client.query(.groundedEvidence(ASKGroundedEvidenceQuery(text: "48,271"))) else {
            throw ASKError.validation("wrong query result")
        }
        return Self(root: root, sourceFile: file, client: client, reference: try #require(pack.evidence.first).reference)
    }

    func record(_ id: String = "fact", evidence: [MemoryEvidenceRef] = []) -> MemoryRecord {
        MemoryRecord(recordID: id, kind: .constraint,
            subject: MemorySubject(kind: "note", subjectID: "contract"), scope: MemoryScope(workspaceID: "test"),
            taskID: "task", statement: "The final amount is 48,271 won. VAT is separate.",
            blocking: true, createdAt: "2026-09-12T00:00:00Z", authorityID: "host", evidenceRefs: evidence)
    }

    func apply(_ transition: MemoryTransition) async throws {
        _ = try await client.apply(try client.plan(.transitionDecisionMemory(ASKTransitionDecisionMemoryCommand(transition: transition))))
    }

    func advice(client other: ASKClient? = nil, budget: ContextBudget = ContextBudget()) async throws -> ASKDecisionMemoryAdviceResult {
        guard case .decisionMemory(let result) = try await (other ?? client).query(.decisionMemory(ASKDecisionMemoryQuery(frame: frame, budget: budget))) else {
            throw ASKError.validation("wrong query result")
        }
        return result
    }
}

@Test(arguments: [false, true])
func currentMemoryRechecksSourceBeforeBudgetAndIntervention(removeSource: Bool) async throws {
    let f = try await GroundedMemoryFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let ref = MemoryEvidenceRef(evidenceID: "exact", reference: f.reference)
    _ = try await f.client.apply(try f.client.plan(.recordDecisionMemory(ASKRecordDecisionMemoryCommand(record: f.record()))))
    try await f.apply(MemoryTransition(transitionID: "v", recordID: "fact", kind: .verify,
        occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "checked", evidenceRefs: [ref]))
    for (id, tier, at) in [("m", MemoryTier.mtem, "2026-09-12T00:02:00Z"), ("l", .ltsm, "2026-09-12T00:03:00Z")] {
        try await f.apply(MemoryTransition(transitionID: id, recordID: "fact", kind: .promote,
            occurredAt: at, actorID: "host", reason: "approved", targetTier: tier))
    }
    let before = try await f.advice()
    #expect(before.context.records.map(\.recordID) == ["fact"])
    #expect(before.intervention.kind == .block)
    if removeSource { try FileManager.default.removeItem(at: f.sourceFile) }
    else { try Data("# Contract\n\nThe revised amount is 96,542 won.\n".utf8).write(to: f.sourceFile) }
    // A successful immutable transition remains a no-op on retry even after
    // source change. It does not certify the evidence as current again.
    try await f.apply(MemoryTransition(transitionID: "v", recordID: "fact", kind: .verify,
        occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "checked", evidenceRefs: [ref]))
    try await f.apply(MemoryTransition(transitionID: "m", recordID: "fact", kind: .promote,
        occurredAt: "2026-09-12T00:02:00Z", actorID: "host", reason: "approved", targetTier: .mtem))
    do {
        try await f.apply(MemoryTransition(transitionID: "v", recordID: "fact", kind: .verify,
            occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "different payload", evidenceRefs: [ref]))
        Issue.record("Same transition identity accepted different content")
    } catch let error as ASKDiagnostic { #expect(error.code == .conflict) }
    let reopened = ASKClient(configuration: ASKConfiguration(workspaceURL: f.root.appendingPathComponent("workspace")))
    let after = try await f.advice(client: reopened, budget: ContextBudget(blockingLTSMTokens: 0))
    #expect(after.context.records.isEmpty)
    #expect(after.intervention.kind == .silence)
    #expect(after.context.generation == before.context.generation)
    #expect(after.context.omitted.first?.evidenceID == "exact")
    #expect(after.context.omitted.first?.detail == (removeSource ? "sourceMissing" : "sourceStale"))
}

@Test(arguments: ["digestMismatch", "rangeUnavailable", "versionMissing"])
func forgedExactMemoryEvidenceDoesNotCommit(reason: String) async throws {
    let f = try await GroundedMemoryFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try await f.client.apply(try f.client.plan(.recordDecisionMemory(ASKRecordDecisionMemoryCommand(record: f.record()))))
    let before = try await f.advice()
    var ref = MemoryEvidenceRef(evidenceID: "exact", reference: f.reference)
    if reason == "digestMismatch" { ref.exactAnchor?.contentSHA256 = String(repeating: "0", count: 64) }
    if reason == "rangeUnavailable" { ref.exactAnchor?.rangeEnd += 1 }
    if reason == "versionMissing" { ref.exactAnchor?.sourceVersionChecksum = "missing" }
    do {
        try await f.apply(MemoryTransition(transitionID: "v", recordID: "fact", kind: .verify,
            occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "claimed", evidenceRefs: [ref]))
        Issue.record("Invalid exact evidence was committed")
    } catch let error as ASKDiagnostic { #expect(error.context["reason"] == reason) }
    let after = try await f.advice()
    #expect(after.context.generation == before.context.generation)
    #expect(after.context.records.first?.verification == .proposed)
}

@Test func staleMemoryCannotBePromotedAndHumanApprovalCannotHideIt() async throws {
    let f = try await GroundedMemoryFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try await f.client.apply(try f.client.plan(.recordDecisionMemory(ASKRecordDecisionMemoryCommand(record: f.record()))))
    let human = MemoryEvidenceRef(evidenceID: "human", kind: .humanApproval, freshness: .fresh, captureReceiptID: "approval")
    try await f.apply(MemoryTransition(transitionID: "v", recordID: "fact", kind: .verify,
        occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "checked",
        evidenceRefs: [human, MemoryEvidenceRef(evidenceID: "exact", reference: f.reference)]))
    let before = try await f.advice()
    try FileManager.default.removeItem(at: f.sourceFile)
    do {
        try await f.apply(MemoryTransition(transitionID: "m", recordID: "fact", kind: .promote,
            occurredAt: "2026-09-12T00:02:00Z", actorID: "host", reason: "promote", targetTier: .mtem))
        Issue.record("A stale source was promoted")
    } catch let error as ASKDiagnostic { #expect(error.context["reason"] == "sourceMissing") }
    let after = try await f.advice()
    #expect(after.context.records.isEmpty)
    #expect(after.context.generation == before.context.generation)
    _ = try await f.client.apply(try f.client.plan(.recordDecisionMemory(ASKRecordDecisionMemoryCommand(record: f.record("human-only")))))
    try await f.apply(MemoryTransition(transitionID: "hv", recordID: "human-only", kind: .verify,
        occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "explicit judgment", evidenceRefs: [human]))
    #expect(try await f.advice().context.records.map(\.recordID) == ["human-only"])
}

@Test func anchorlessMemoryCannotEnterTheCurrentJournal() async throws {
    let f = try await GroundedMemoryFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let anchorlessJSON = "{\"evidenceID\":\"anchorless\",\"kind\":\"pageIndexAnchor\",\"freshness\":\"fresh\",\"sourceID\":\"source\",\"nodeID\":\"node\"}"
    let anchorless = try JSONDecoder().decode(MemoryEvidenceRef.self, from: Data(anchorlessJSON.utf8))
    #expect(throws: ASKError.self) { try anchorless.validate() }
    let journal = ASKWorkWikiDecisionMemoryJournal(decisionMemoryRootURL: ASKConfiguration(workspaceURL: f.root.appendingPathComponent("workspace")).resolvedVaultURL)
    _ = try await journal.append(f.record())
    let before = try await journal.snapshot(asOf: f.frame.requestedAt)
    await #expect(throws: ASKError.self) {
        try await journal.append(MemoryTransition(transitionID: "v", recordID: "fact", kind: .verify,
            occurredAt: "2026-09-12T00:01:00Z", actorID: "host", reason: "unverifiable", evidenceRefs: [anchorless]))
    }
    #expect(try await journal.snapshot(asOf: f.frame.requestedAt) == before)
}
