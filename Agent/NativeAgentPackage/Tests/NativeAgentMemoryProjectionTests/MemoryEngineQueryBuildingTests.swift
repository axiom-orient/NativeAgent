import Foundation
import Testing

@testable import NativeAgentMemoryProjection

@Test
func typedSearchRejectsBlankQueriesWithoutOpeningStorage() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-query-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    do {
        _ = try await engine.search(
            scope: AgentMemoryScope(profileID: "p", userID: "u", namespace: "n"),
            query: ProjectionSearchQuery(query: "   ", kinds: [], fromMS: nil, toMS: nil, historical: false, limit: 8)
        )
        Issue.record("expected missing query validation")
    } catch let error as AgentMemoryError {
        #expect(error.kind == .validation)
        #expect(error.code == "missing_query")
    }
}

@Test
func typedSearchIsBoundedAndReturnsEventEvidence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-search-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    _ = try await engine.initialize()
    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    let turns = (0..<12).map {
        AgentMemoryTurn(
            id: "message-\($0)",
            role: .user,
            content: "bounded event entry \($0)",
            timestampMilliseconds: Int64($0 + 1),
            sessionID: "session"
        )
    }
    _ = try await engine.ingest(scope: scope, turns: turns)
    let hits = try await engine.search(
        scope: scope,
        query: ProjectionSearchQuery(query: "bounded event", kinds: [], fromMS: nil, toMS: nil, historical: false, limit: 99)
    )
    #expect(hits.count <= 8)
    #expect(hits.allSatisfy { $0.layer == "event" })
    try await engine.close()
}
