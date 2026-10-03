import Foundation
import Testing

@testable import NativeAgentMemory

@Test
func recallUsesTypedMatchesAndExcludesTheCurrentMessage() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-recall-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(
        configuration: MemoryConfiguration(dataDirectory: root)
    )
    let scope = MemoryScope(profileID: "p", userID: "u", sessionKey: "s", namespace: "n")
    _ = try await controller.capture(
        scope: scope,
        turns: [
            MemoryTurn(id: "current", role: .user, content: "current request", timestampMilliseconds: 1),
            MemoryTurn(id: "older", role: .assistant, content: "older durable answer", timestampMilliseconds: 2)
        ]
    )
    let context = try await controller.recall(
        scope: scope,
        query: "request",
        excludingMessageIDs: ["current"]
    )
    #expect(context.matches.contains { $0.sourceMessageIDs.contains("current") } == false)
    #expect(context.memoryContext.utf8.count <= 8 * 1_024)
    #expect(context.matches.count <= 8)
}

@Test
func deletingAScopeRemovesItsSearchProjection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-delete-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MemoryController(configuration: MemoryConfiguration(dataDirectory: root))
    let scope = MemoryScope(profileID: "p", userID: "u", sessionKey: "s", namespace: "n")
    _ = try await controller.capture(
        scope: scope,
        turns: [MemoryTurn(id: "delete-me", role: .user, content: "remove this projection", timestampMilliseconds: 1)]
    )
    #expect((try await controller.search(scope: scope, query: "projection")).matches.isEmpty == false)
    try await controller.delete(scope: scope)
    #expect((try await controller.search(scope: scope, query: "projection")).matches.isEmpty)
}
