import Foundation
import Testing
@testable import PageIndex

struct SourceIndexTransactionTests {
    @Test func newTargetsUnderPrivateWorkspacePublishWithoutFalseEscape() throws {
        #if os(macOS)
        let root = URL(fileURLWithPath: "/private/tmp/ask-transaction-\(UUID().uuidString)")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #endif
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("artifacts/src_\(String(repeating: "a", count: 64)).json")
        let manifest = root.appendingPathComponent(SourceIndexStore.manifestFileName)
        try SourceIndexTransaction(root: root).publish([
            .init(relativePath: "artifacts/src_\(String(repeating: "a", count: 64)).json", data: Data("artifact".utf8)),
            .init(relativePath: SourceIndexStore.manifestFileName, data: Data("{}".utf8))
        ])
        #expect(try String(contentsOf: artifact, encoding: .utf8) == "artifact")
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "{}")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(SourceIndexTransaction.pendingFileName).path))
    }

    @Test func publicationRejectsSymbolicLinkTargetsBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let manifest = root.appendingPathComponent(SourceIndexStore.manifestFileName)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: sentinel)
        #expect(throws: ASKPageIndexError.self) {
            try SourceIndexTransaction(root: root).publish([
                .init(relativePath: SourceIndexStore.manifestFileName, data: Data("{}".utf8))
            ])
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    }

    @Test func publicationRejectsRelativeEscapesBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transaction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.deletingLastPathComponent().appendingPathComponent("sentinel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sentinel) }
        try Data("preserve".utf8).write(to: sentinel)

        #expect(throws: ASKPageIndexError.self) {
            try SourceIndexTransaction(root: root).publish([
                .init(relativePath: "../\(sentinel.lastPathComponent)", data: Data("overwrite".utf8)),
                .init(relativePath: SourceIndexStore.manifestFileName, data: Data("{}".utf8))
            ])
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(SourceIndexTransaction.pendingFileName).path))
    }

    @Test func pendingPublicationBlocksReadsAndRecoveryIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent(SourceIndexStore.manifestFileName)
        let previous = Data("{}".utf8)
        try previous.write(to: manifest)
        let pending: [String: Any] = ["version": 1, "files": [["path": SourceIndexStore.manifestFileName,
            "data": previous.base64EncodedString()]]]
        try JSONSerialization.data(withJSONObject: pending).write(to: root.appendingPathComponent(SourceIndexTransaction.pendingFileName))
        let store = try SourceIndexStore(workspaceURL: root)
        await #expect(throws: ASKPageIndexError.self) { try await store.list() }
        #expect(try await store.recoverPendingWrite())
        #expect(try await store.recoverPendingWrite() == false)
        #expect(try await store.list().isEmpty)
        #expect(try Data(contentsOf: manifest) == previous)
    }

    @Test func corruptedRecoveryRecordCannotEscapeOrDisappear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "files": [
            ["path": "../sentinel", "data": Data("overwrite".utf8).base64EncodedString()],
            ["path": SourceIndexStore.manifestFileName, "data": Data("{}".utf8).base64EncodedString()]]])
        let pending = root.appendingPathComponent(SourceIndexTransaction.pendingFileName)
        try bytes.write(to: pending)
        let store = try SourceIndexStore(workspaceURL: root)
        await #expect(throws: ASKPageIndexError.self) { try await store.recoverPendingWrite() }
        #expect(try Data(contentsOf: pending) == bytes)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    }

    @Test func recoveringMissingIndexDoesNotCreateIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SourceIndexStore(workspaceURL: root)
        #expect(try await store.recoverPendingWrite() == false)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
