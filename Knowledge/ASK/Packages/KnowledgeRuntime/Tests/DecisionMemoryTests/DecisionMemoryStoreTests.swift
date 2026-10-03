import Foundation
import Testing
@testable import DecisionMemory
@testable import KnowledgeCore

struct DecisionMemoryStoreTests {
    private func withTemporaryStore(
        _ body: (DecisionMemoryStore, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-decision-memory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(DecisionMemoryStore(root: root), root)
    }

    private func record(
        recordID: String = "mem_001",
        statement: String = "Source-backed facts require anchors."
    ) -> MemoryRecord {
        MemoryRecord(
            recordID: recordID,
            kind: .constraint,
            subject: MemorySubject(kind: "package", subjectID: "pageindex"),
            scope: MemoryScope(workspaceID: "ask", projectIDs: ["pageindex"]),
            taskID: "task_001",
            statement: statement,
            priority: 90,
            blocking: true,
            createdAt: "2026-08-01T00:00:00Z",
            authorityID: "auth_pageindex"
        )
    }

    private func verification() -> MemoryTransition {
        MemoryTransition(
            transitionID: "transition_001",
            recordID: "mem_001",
            kind: .verify,
            occurredAt: "2026-08-01T00:01:00Z",
            actorID: "reviewer",
            reason: "anchor verified",
            evidenceRefs: [
                MemoryEvidenceRef(
                    evidenceID: "evidence_001",
                    kind: .pageIndexAnchor,
                    freshness: .fresh,
                    sourceID: "src_pageindex",
                    nodeID: "node_001",
                    exactAnchor: MemoryExactSourceAnchor(sourceVersionChecksum: "source-revision",
                        coordinateSpace: "line", rangeStart: 1, rangeEnd: 1,
                        contentSHA256: String(repeating: "a", count: 64))
                ),
            ]
        )
    }

    @Test
    func unsupportedStorageRejectsReplayAndAppendWithoutMovingOrDeletingData() async throws {
        try await withTemporaryStore { store, root in
            let directory = root.appendingPathComponent(".ask/decision-memory/v1/records")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("mem_001.json")
            let preserved = Data("unsupported journal bytes".utf8)
            try preserved.write(to: url)
            await #expect(throws: ASKError.self) { try await store.replay(asOf: "2026-08-01T00:04:00Z") }
            await #expect(throws: ASKError.self) { try await store.append(record()) }
            #expect(try Data(contentsOf: url) == preserved)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".ask/decision-memory/v2").path))
        }
    }

    @Test
    func unsupportedEntryVersionRejectsReplayAndIdenticalTransitionLookup() async throws {
        try await withTemporaryStore { store, root in
            let directory = root.appendingPathComponent(".ask/decision-memory/v2/records")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var unsupported = record()
            unsupported.version = "ask-decision-memory-record.v1"
            let url = directory.appendingPathComponent("mem_001.json")
            let preserved = try CanonicalJSON.data(for: unsupported)
            try preserved.write(to: url)
            await #expect(throws: ASKError.self) { try await store.replay(asOf: "2026-08-01T00:04:00Z") }
            await #expect(throws: ASKError.self) { try await store.containsIdenticalTransition(verification()) }
            #expect(try Data(contentsOf: url) == preserved)
        }
    }

    @Test
    func journalIsIdempotentReplaysAndRebuildsDerivedMarkdown() async throws {
        try await withTemporaryStore { store, root in
            let inserted = try await store.append(record())
            #expect(inserted.recordCount == 1)
            let duplicate = try await store.append(record())
            #expect(duplicate.generation == inserted.generation)

            _ = try await store.append(verification())
            _ = try await store.append(
                MemoryTransition(
                    transitionID: "transition_002",
                    recordID: "mem_001",
                    kind: .promote,
                    occurredAt: "2026-08-01T00:02:00Z",
                    actorID: "reviewer",
                    reason: "project reuse",
                    targetTier: .mtem
                )
            )
            _ = try await store.append(
                MemoryTransition(
                    transitionID: "transition_003",
                    recordID: "mem_001",
                    kind: .promote,
                    occurredAt: "2026-08-01T00:03:00Z",
                    actorID: "owner",
                    reason: "approved invariant",
                    targetTier: .ltsm
                )
            )

            let materialization = try await store.materialize(asOf: "2026-08-01T00:04:00Z")
            #expect(materialization.files == ["memory/README.md", "memory/ltsm/ask.md"])
            let projectionURL = root.appendingPathComponent("memory/ltsm/ask.md")
            let original = try String(contentsOf: projectionURL, encoding: .utf8)
            #expect(original.contains("mem_001"))
            #expect((try await store.projectionDrift(asOf: "2026-08-01T00:04:00Z")).isClean)

            try FileManager.default.removeItem(at: root.appendingPathComponent("memory"))
            #expect(!(try await store.projectionDrift(asOf: "2026-08-01T00:04:00Z")).isClean)
            _ = try await store.materialize(asOf: "2026-08-01T00:04:00Z")
            #expect(try String(contentsOf: projectionURL, encoding: .utf8) == original)
        }
    }

    @Test
    func conflictingRecordBytesAreRejected() async throws {
        try await withTemporaryStore { store, _ in
            _ = try await store.append(record())
            await #expect(throws: ASKError.self) {
                _ = try await store.append(record(statement: "Different statement."))
            }
        }
    }

    @Test
    func conflictingBatchDoesNotPersistEarlierRecords() async throws {
        try await withTemporaryStore { store, root in
            _ = try await store.append(record())
            let existingURL = root.appendingPathComponent(".ask/decision-memory/v2/records/mem_001.json")
            let existingBytes = try Data(contentsOf: existingURL)
            await #expect(throws: ASKError.self) {
                _ = try await store.append([
                    record(recordID: "mem_002", statement: "A new record."),
                    record(statement: "Conflicting bytes.")
                ])
            }

            let replay = try await store.replay(asOf: "2026-08-01T00:02:00Z")
            #expect(replay.recordCount == 1)
            #expect(!replay.snapshot.states.contains { $0.record.recordID == "mem_002" })
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".ask/decision-memory/v2/records/mem_002.json").path))
            #expect(try Data(contentsOf: existingURL) == existingBytes)
        }
    }
}
