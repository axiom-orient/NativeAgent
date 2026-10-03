import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct VaultHardeningTests {
    @Test
    func authorityYAMLEscapesQuotedAndMultilineScalars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = Vault(root: root)
        let record = AuthorityRecord(
            version: "1",
            recordID: "auth_1",
            recordType: "runtime",
            subjectKind: "runtime",
            subjectID: "ask-runtime",
            factScopeKey: "runtime_state",
            approvalState: .approved,
            valueFields: [
                "line\nbreak": "value\\slash\"quote\nnext"
            ],
            effectiveFrom: "2026-04-10T00:00:00Z",
            effectiveTo: nil,
            approvedBy: "owner\"name\nline",
            supersedesID: nil
        )

        let rendered = vault.renderAuthorityYAML(record)

        #expect(rendered.contains("approved_by: \"owner\\\"name\\nline\""))
        #expect(rendered.contains("  \"line\\nbreak\": \"value\\\\slash\\\"quote\\nnext\""))
    }

    @Test
    func vaultWriteHelpersRejectStandardizedPathsOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = Vault(root: root)
        let escapedURL = root.appendingPathComponent("../escape.txt", isDirectory: false).standardizedFileURL

        #expect(throws: ASKError.self) {
            try vault.writeTextFile(escapedURL, content: "escape")
        }
        #expect(FileManager.default.fileExists(atPath: escapedURL.path) == false)
    }

    @Test
    func vaultWriteHelpersAcceptEquivalentRootAliases() throws {
        // Construct the alias rather than assuming the host has macOS's
        // /var -> /private/var mapping. Exercise the same physical identity.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolvedRoot = root.appendingPathComponent("physical")
        let aliasedRoot = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasedRoot, withDestinationURL: resolvedRoot)
        let vault = Vault(root: resolvedRoot)
        try vault.writeTextFile(aliasedRoot.appendingPathComponent("nested/value.txt"), content: "alias-safe")
        #expect(try String(contentsOf: resolvedRoot.appendingPathComponent("nested/value.txt"), encoding: .utf8) == "alias-safe\n")
    }

    @Test
    func missingVaultReadIsSideEffectFree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = Vault(root: root)
        let snapshot = try vault.loadStoreFromJournal()

        #expect(snapshot.report.approvedPatchIDs.isEmpty)
        #expect(snapshot.report.rejectedPatchIDs.isEmpty)
        #expect(snapshot.report.pendingPatchIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func journalDirectoryReadFailureIsNotTreatedAsAnEmptyJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = Vault(root: root)
        _ = try vault.bootstrap()
        let patchesURL = root.appendingPathComponent(".ask/journal/patches", isDirectory: true)
        try FileManager.default.removeItem(at: patchesURL)
        try Data("not-a-directory".utf8).write(to: patchesURL)

        #expect(throws: Error.self) {
            _ = try vault.loadStoreFromJournal()
        }
    }

    @Test
    func corruptGenerationMarkerIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = Vault(root: root)
        _ = try vault.bootstrap()
        let markerURL = vault.generationMarkerURL()
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: markerURL)

        #expect(throws: Error.self) {
            _ = try vault.readGenerationMarker()
        }
    }

    @Test
    func corruptMirrorIsNotReportedAsAnEmptyMirror() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = Vault(root: root)
        _ = try vault.bootstrap()
        let mirrorURL = vault.mirrorURL()
        try FileManager.default.createDirectory(at: mirrorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-sqlite-database".utf8).write(to: mirrorURL)

        #expect(throws: Error.self) {
            _ = try vault.dumpState()
        }
    }

}
