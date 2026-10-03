import Foundation
import Testing
import KnowledgePresentation

struct KnowledgePresentationBoundaryTests {
    @Test
    func presentationBundlePathRejectsTraversal() throws {
        let paths = ASKKnowledgeWorkspacePaths(rootURL: URL(fileURLWithPath: "/tmp/ask-presentation-test"))

        #expect(throws: ASKKnowledgeWorkspaceError.invalidPresentationBundleName("../escape")) {
            _ = try paths.presentationBundleRoot(named: "../escape")
        }
    }

    @Test
    func presentationBundlePathIsDeterministic() throws {
        let paths = ASKKnowledgeWorkspacePaths(rootURL: URL(fileURLWithPath: "/tmp/ask-presentation-test"))

        let first = try paths.presentationBundleRoot(named: "wiki/ask")
        let second = try paths.presentationBundleRoot(named: "wiki/ask")

        #expect(first == second)
        #expect(first.path.hasSuffix("ASKPageBundles/wiki/ask"))
    }

    @Test
    func pageIndexBindingStoreRejectsDuplicateFileEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-presentation-bindings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ASKPageIndexSourceBindingStore(rootURL: root)
        let duplicate = [
            ASKPageIndexSourceBinding(askSourceID: "ask-1", pageIndexSourceID: "page-1"),
            ASKPageIndexSourceBinding(askSourceID: " ask-1 ", pageIndexSourceID: "page-2")
        ]
        try JSONEncoder().encode(duplicate).write(to: store.fileURL)

        #expect(throws: ASKKnowledgeWorkspaceError.invalidASKSourceID("duplicate page-index binding for `ask-1`")) {
            _ = try store.load()
        }
    }

    @Test
    func pageIndexBindingStoreRejectsDuplicateUpsertInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-presentation-bindings-upsert-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ASKPageIndexSourceBindingStore(rootURL: root)

        #expect(throws: ASKKnowledgeWorkspaceError.invalidASKSourceID("duplicate page-index binding for `ask-1`")) {
            try store.upsert([
                ASKPageIndexSourceBinding(askSourceID: "ask-1", pageIndexSourceID: "page-1"),
                ASKPageIndexSourceBinding(askSourceID: " ask-1 ", pageIndexSourceID: "page-2")
            ])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
