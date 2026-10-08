import Foundation
import Testing
import KnowledgeCore
@testable import KnowledgeRuntime

struct SearchValidationTests {
    @Test
    func negativeSearchLimitFailsWithoutCreatingVault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-search-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ASKError.validation("search limit must be non-negative")) {
            try ASKRuntime(root: root).search("query", limit: -1)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func mirrorFirstRejectsNegativeSearchLimitBeforeOpeningVault() {
        #expect(throws: ASKError.validation("search limit must be non-negative")) {
            try searchMirrorFirst(
                root: "/tmp/ask-search-validation-missing",
                query: "query",
                limit: -1
            )
        }
    }

    @Test
    func mirrorCandidatesRejectNegativeSearchLimitBeforeOpeningDatabase() {
        #expect(throws: ASKError.validation("search limit must be non-negative")) {
            try searchMirrorCandidates(
                at: URL(fileURLWithPath: "/tmp/ask-search-validation-missing.sqlite"),
                query: "query",
                limit: -1
            )
        }
    }

    @Test
    func zeroSearchLimitReturnsNoHits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-search-zero-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try ASKRuntime(root: root).search("query", limit: 0)
        #expect(result.hits.isEmpty)
    }
}
