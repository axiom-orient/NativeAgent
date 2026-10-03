import Foundation
import Testing
import KnowledgeCore
@testable import KnowledgeRuntime

struct CaptureImportBoundaryTests {
    private struct Capture {
        let root: URL
        let vault: URL
        let staging: URL
        let directory: URL
        let raw: URL
        let manifestURL: URL
        var manifest: CollectedCaptureManifest
        var collected: CollectedSource

        init(rawRelpath: String = "raw/evidence/source.txt") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            vault = root.appendingPathComponent("vault")
            staging = root.appendingPathComponent("staging")
            directory = staging.appendingPathComponent(".ask/collector/local-file/source")
            raw = staging.appendingPathComponent(rawRelpath)
            manifestURL = directory.appendingPathComponent("capture_manifest.json")
            let bytes = Data("original evidence".utf8)
            let hash = ASKSHA256.prefixedDigest(bytes)
            manifest = CollectedCaptureManifest(sourceID: "source", connector: "local-file", transport: "file",
                originalURL: "file:///source.txt", finalURL: "file:///source.txt", title: "Source",
                observedAt: "2026-09-06T00:00:00Z", capturedAt: "2026-09-06T00:00:00Z",
                rawRelpath: rawRelpath, noteRelpath: ".ask/collector/local-file/source/curated_note.md",
                contentHash: hash, mimeType: "text/plain", language: "en", tags: [])
            collected = CollectedSource(sourceID: "source", connector: "local-file", sourceKind: .file,
                title: "Source", observedAt: manifest.observedAt, capturedAt: manifest.capturedAt,
                rawRelpath: rawRelpath, contentHash: hash, mimeType: "text/plain", language: "en", tags: [])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: raw)
            try Data("# Source\n\nOriginal evidence.\n".utf8).write(to: directory.appendingPathComponent("curated_note.md"))
            try save()
        }

        func save() throws {
            try CanonicalJSON.data(for: manifest).write(to: manifestURL, options: .atomic)
            try CanonicalJSON.data(for: collected).write(to: directory.appendingPathComponent("collected_source.json"), options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func matchingCaptureImportsAndReimportsWithoutChangingRawBytes() throws {
        let input = try Capture(); defer { input.remove() }
        let runtime = ASKRuntime(root: input.vault)
        let first = try runtime.importCollected(input.manifestURL)
        let second = try runtime.importCollected(input.directory)
        #expect(first == second)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.rawPath)) == Data(contentsOf: input.raw))
    }

    @Test(arguments: [true, false])
    func bothHashClaimsMustMatchTheActualBytes(changeManifest: Bool) throws {
        var input = try Capture(); defer { input.remove() }
        if changeManifest { input.manifest.contentHash = ASKSHA256.prefixedDigest(Data("other".utf8)) }
        else { input.collected.contentHash = ASKSHA256.prefixedDigest(Data("other".utf8)) }
        try input.save()
        #expect(throws: ASKError.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
        #expect(!FileManager.default.fileExists(atPath: input.vault.appendingPathComponent(input.manifest.rawRelpath).path))
    }

    @Test func captureCannotWriteIntoCanonicalJournalNamespace() throws {
        let input = try Capture(rawRelpath: ".ask/journal/events/injected.json"); defer { input.remove() }
        let target = input.vault.appendingPathComponent(input.manifest.rawRelpath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("canonical sentinel".utf8)
        try original.write(to: target)
        #expect(throws: ASKError.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test(arguments: ["raw", "curated_note.md", "collected_source.json", "capture_manifest.json"])
    func linkedInputCannotReadOutsideStaging(file: String) throws {
        let input = try Capture(); defer { input.remove() }
        let selected = file == "raw" ? input.raw : input.directory.appendingPathComponent(file)
        let external = input.root.appendingPathComponent("external-" + file)
        try FileManager.default.moveItem(at: selected, to: external)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: external)
        #expect(throws: ASKError.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
        #expect(!FileManager.default.fileExists(atPath: input.vault.appendingPathComponent(input.manifest.rawRelpath).path))
    }

    @Test func anExistingRawRevisionIsNotOverwrittenByAnotherCapture() throws {
        var input = try Capture(); defer { input.remove() }
        let runtime = ASKRuntime(root: input.vault)
        let imported = try runtime.importCollected(input.manifestURL)
        let rawURL = URL(fileURLWithPath: imported.rawPath)
        let original = try Data(contentsOf: rawURL)
        let replacement = Data("different revision".utf8)
        try replacement.write(to: input.raw)
        input.manifest.contentHash = ASKSHA256.prefixedDigest(replacement)
        input.collected.contentHash = input.manifest.contentHash
        try input.save()
        #expect(throws: ASKError.self) { try runtime.importCollected(input.manifestURL) }
        #expect(try Data(contentsOf: rawURL) == original)
    }

    @Test func malformedNoteFailsBeforeAnyCaptureBytesArePublished() throws {
        let input = try Capture(); defer { input.remove() }
        try Data([0xff, 0xfe, 0xff]).write(to: input.directory.appendingPathComponent("curated_note.md"))
        #expect(throws: Error.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
        #expect(!FileManager.default.fileExists(atPath: input.vault.appendingPathComponent(input.manifest.rawRelpath).path))
    }

    @Test func declaredNoteLocationMustMatchTheImportedNote() throws {
        var input = try Capture(); defer { input.remove() }
        input.manifest.noteRelpath = "unrelated.md"
        try input.save()
        #expect(throws: ASKError.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
    }

    @Test func invalidDestinationFailsBeforeRawPublication() throws {
        let input = try Capture(); defer { input.remove() }
        let noteDestination = input.vault.appendingPathComponent(".ask/collector/local-file/source/curated_note.md")
        try FileManager.default.createDirectory(at: noteDestination, withIntermediateDirectories: true)
        #expect(throws: ASKError.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
        #expect(!FileManager.default.fileExists(atPath: input.vault.appendingPathComponent(input.manifest.rawRelpath).path))
    }

    @Test func internalRawSymlinkCannotRedirectIntoJournal() throws {
        let input = try Capture(); defer { input.remove() }
        let journal = input.vault.appendingPathComponent(".ask/journal")
        let rawDirectory = input.vault.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: rawDirectory.appendingPathComponent("evidence"), withDestinationURL: journal)
        #expect(throws: ASKError.self) { try ASKRuntime(root: input.vault).importCollected(input.manifestURL) }
        #expect(!FileManager.default.fileExists(atPath: journal.appendingPathComponent("source.txt").path))
    }

    @Test func fullReadScopeComesFromTheImportOwnerWithoutCreatingVault() throws {
        let input = try Capture(); defer { input.remove() }
        #expect(try ASKRuntime.captureStagingRoot(for: input.manifestURL).path == input.staging.path)
        #expect(try ASKRuntime.captureStagingRoot(for: input.directory).path == input.staging.path)
        #expect(!FileManager.default.fileExists(atPath: input.vault.path))
    }
}