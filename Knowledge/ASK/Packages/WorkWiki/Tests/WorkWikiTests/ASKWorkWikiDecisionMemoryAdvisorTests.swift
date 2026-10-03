import DecisionMemory
import KnowledgeCore
import XCTest
@testable import WorkWiki

final class ASKWorkWikiDecisionMemoryAdvisorTests: XCTestCase, @unchecked Sendable {
    func testAdvisorReturnsBlockAsAdviceWithoutMaterializingOrActing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-memory-advisor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DecisionMemoryStore(root: root)
        let evidence = MemoryEvidenceRef(
            evidenceID: "receipt_001",
            kind: .humanApproval,
            freshness: .fresh,
            captureReceiptID: "receipt_001"
        )
        let record = MemoryRecord(
            recordID: "mem_irreversible_constraint",
            kind: .constraint,
            subject: MemorySubject(kind: "project", subjectID: "pageindex"),
            scope: MemoryScope(workspaceID: "ask", riskTags: ["irreversible"]),
            statement: "Do not replace source evidence without verification.",
            priority: 100,
            blocking: true,
            createdAt: "2026-08-01T00:00:00Z",
            authorityID: "authority_pageindex"
        )
        _ = try await store.append(record)
        _ = try await store.append(MemoryTransition(
            transitionID: "transition_verify",
            recordID: record.recordID,
            kind: .verify,
            occurredAt: "2026-08-01T00:01:00Z",
            actorID: "reviewer",
            reason: "source reviewed",
            evidenceRefs: [evidence]
        ))
        _ = try await store.append(MemoryTransition(
            transitionID: "transition_mtem",
            recordID: record.recordID,
            kind: .promote,
            occurredAt: "2026-08-01T00:02:00Z",
            actorID: "reviewer",
            reason: "active procedure",
            targetTier: .mtem
        ))
        _ = try await store.append(MemoryTransition(
            transitionID: "transition_ltsm",
            recordID: record.recordID,
            kind: .promote,
            occurredAt: "2026-08-01T00:03:00Z",
            actorID: "reviewer",
            reason: "durable constraint",
            targetTier: .ltsm
        ))

        let advice = try await ASKWorkWikiDecisionMemoryAdvisor(store: store).advise(
            for: TaskFrame(
                taskID: "task_deploy",
                workspaceID: "ask",
                riskTags: ["irreversible"],
                requestedAt: "2026-08-01T00:10:00Z"
            )
        )

        XCTAssertEqual(advice.intervention.kind, .block)
        XCTAssertEqual(advice.intervention.recordIDs, [record.recordID])
        XCTAssertEqual(advice.context.records.map(\.recordID), [record.recordID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory").path))
    }
}
