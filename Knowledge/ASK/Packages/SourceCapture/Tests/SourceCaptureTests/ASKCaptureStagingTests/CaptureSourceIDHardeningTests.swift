import Foundation
import Testing
@testable import KnowledgeCore
@testable import SourceCapture

struct CaptureSourceIDHardeningTests {
    @Test
    func collectedCaptureManifestRejectsPathUnsafeSourceID() {
        #expect(throws: ASKError.self) {
            try CollectedCaptureManifest(
                sourceID: "../escape",
                connector: "official-web-snapshot",
                transport: "html_text",
                originalURL: "https://example.com/escape",
                finalURL: "https://example.com/escape",
                title: "Escape",
                observedAt: "2026-04-10T00:00:00Z",
                capturedAt: "2026-04-10T00:00:00Z",
                rawRelpath: "raw/evidence/2026-04-10/src_escape.html",
                noteRelpath: ".ask/collector/web/src_escape/curated_note.md",
                contentHash: "sha256:test",
                mimeType: "text/html",
                language: "en",
                tags: ["capture"]
            ).validate()
        }
    }

    @Test
    func collectedSourceRejectsPathUnsafeSourceID() {
        #expect(throws: ASKError.self) {
            try CollectedSource(
                sourceID: "bad/source",
                connector: "official-web-snapshot",
                sourceKind: .url,
                title: "Escape",
                observedAt: "2026-04-10T00:00:00Z",
                capturedAt: "2026-04-10T00:00:00Z",
                rawRelpath: "raw/evidence/2026-04-10/src_escape.html",
                contentHash: "sha256:test",
                mimeType: "text/html",
                language: "en",
                tags: ["capture"]
            ).validate()
        }
    }

    @Test
    func captureStagerRejectsPathUnsafeSourceIDBeforeWritingFiles() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let bundle = WebCaptureBundle(
            manifest: CollectedCaptureManifest(
                sourceID: "../escape",
                connector: "official-web-snapshot",
                transport: "html_text",
                originalURL: "https://example.com/escape",
                finalURL: "https://example.com/escape",
                title: "Escape",
                observedAt: "2026-04-10T00:00:00Z",
                capturedAt: "2026-04-10T00:00:00Z",
                rawRelpath: "raw/evidence/2026-04-10/src_escape.html",
                noteRelpath: ".ask/collector/web/src_escape/curated_note.md",
                contentHash: "sha256:test",
                mimeType: "text/html",
                language: "en",
                tags: ["capture"]
            ),
            collectedSource: CollectedSource(
                sourceID: "../escape",
                connector: "official-web-snapshot",
                sourceKind: .url,
                title: "Escape",
                observedAt: "2026-04-10T00:00:00Z",
                capturedAt: "2026-04-10T00:00:00Z",
                rawRelpath: "raw/evidence/2026-04-10/src_escape.html",
                contentHash: "sha256:test",
                mimeType: "text/html",
                language: "en",
                tags: ["capture"]
            ),
            rawBytes: Data("escape".utf8),
            curatedNoteMD: "# Escape\n"
        )

        #expect(throws: ASKError.self) {
            try CaptureStager.stage(bundle, at: stagingRoot)
        }
        #expect(FileManager.default.fileExists(atPath: stagingRoot.path) == false)
    }

    @Test
    func captureStagerRejectsMismatchedBundleBeforeCreatingTransaction() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-stage-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        var bundle = try WebCapture.captureHTMLText(
            "<html><body>mismatch</body></html>",
            pageURL: "https://example.com/mismatch",
            sourceID: "src_mismatch",
            observedAt: "2026-04-10T00:00:00Z",
            rawRelpath: "raw/evidence/2026-04-10/src_mismatch.html"
        )
        bundle.collectedSource.sourceID = "src_other"

        #expect(throws: ASKError.self) {
            try CaptureStager.stage(bundle, at: stagingRoot)
        }
        #expect(FileManager.default.fileExists(atPath: stagingRoot.path) == false)
    }

    @Test
    func captureStagerRejectsPreexistingRawSymlink() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-stage-symlink-\(UUID().uuidString)", isDirectory: true)
        let outsideRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-stage-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let rawLink = stagingRoot.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rawLink, withDestinationURL: outsideRoot)

        let bundle = try WebCapture.captureHTMLText(
            "<html><body>symlink</body></html>",
            pageURL: "https://example.com/symlink",
            sourceID: "src_symlink",
            observedAt: "2026-04-10T00:00:00Z",
            rawRelpath: "raw/evidence/2026-04-10/src_symlink.html"
        )

        #expect(throws: ASKError.self) {
            try CaptureStager.stage(bundle, at: stagingRoot)
        }
        #expect(FileManager.default.fileExists(atPath: outsideRoot.appendingPathComponent("evidence").path) == false)
    }

    @Test
    func captureStagerRejectsSymlinkedStagingRoot() throws {
        let realRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-stage-real-root-\(UUID().uuidString)", isDirectory: true)
        let linkedRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-stage-linked-root-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: realRoot)
            try? FileManager.default.removeItem(at: linkedRoot)
        }
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        let bundle = try WebCapture.captureHTMLText(
            "<html><body>linked root</body></html>",
            pageURL: "https://example.com/linked-root",
            sourceID: "src_linked_root",
            observedAt: "2026-04-10T00:00:00Z",
            rawRelpath: "raw/evidence/2026-04-10/src_linked_root.html"
        )

        #expect(throws: ASKError.self) {
            try CaptureStager.stage(bundle, at: linkedRoot)
        }
        #expect(FileManager.default.fileExists(atPath: realRoot.appendingPathComponent(".ask").path) == false)
    }
}
