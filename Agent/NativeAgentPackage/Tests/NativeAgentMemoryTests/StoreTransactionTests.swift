import Foundation
import Testing

@testable import NativeAgentMemory

@Test
func preparationIsSerializedAndRetryableAfterAWorkspaceFailure() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-prepare-\(UUID().uuidString)", isDirectory: true)
    let blocked = parent.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try Data("blocking-file".utf8).write(to: blocked)
    defer { try? FileManager.default.removeItem(at: parent) }

    let controller = MemoryController(
        configuration: MemoryConfiguration(dataDirectory: blocked)
    )
    await #expect(throws: (any Error).self) {
        _ = try await controller.prepare()
    }
    try FileManager.default.removeItem(at: blocked)
    _ = try await controller.prepare()
}
