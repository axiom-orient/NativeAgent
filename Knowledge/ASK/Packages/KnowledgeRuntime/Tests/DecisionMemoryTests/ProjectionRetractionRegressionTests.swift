import Foundation
import Testing
import DecisionMemory
import KnowledgeCore

struct ProjectionRetractionRegressionTests {
    @Test func retractMustRemovePreviouslyMaterializedStatement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-memory-observed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DecisionMemoryStore(root: root)
        let record = MemoryRecord(recordID: "mem_audit", kind: .constraint,
            subject: MemorySubject(kind: "package", subjectID: "pageindex"),
            scope: MemoryScope(workspaceID: "ask"), taskID: "task_audit",
            statement: "RETRACTED BLOCKING INSTRUCTION", priority: 90, blocking: true,
            createdAt: "2026-09-12T00:00:00Z")
        _ = try await store.append(record)
        _ = try await store.materialize(asOf: "2026-09-12T00:01:00Z")
        let oldURL = root.appendingPathComponent("memory/stim/ask.md")
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        _ = try await store.append(MemoryTransition(transitionID: "tr_retract", recordID: "mem_audit", kind: .retract,
            occurredAt: "2026-09-12T00:02:00Z", actorID: "tester", reason: "obsolete"))
        let replay = try await store.replay(asOf: "2026-09-12T00:03:00Z")
        #expect(replay.snapshot.states.allSatisfy { !$0.isActive })
        _ = try await store.materialize(asOf: "2026-09-12T00:03:00Z")
        let drift = try await store.projectionDrift(asOf: "2026-09-12T00:03:00Z")
        let stale = (try? String(contentsOf: oldURL, encoding: .utf8))?.contains("RETRACTED BLOCKING INSTRUCTION") == true
        #expect(!stale)
        #expect(drift.isClean)
    }
}
