import Foundation
import Testing
import KnowledgeRuntime

struct PendingPatchReadTests {
    @Test func missingPatchReadDoesNotBootstrapMissingOrEmptyVault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ASKRuntime(root: root)
        #expect(try runtime.snapshot().fileCount == 0)
        #expect(try runtime.patchPlan(patchID: "missing") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(try runtime.snapshot().fileCount == 0)
        #expect(try runtime.patchPlan(patchID: "missing") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
