import Foundation
import Testing
@testable import KnowledgeCore
@testable import SourceCapture

struct HTMLCaptureTests {
    @Test
    func extractionModelsDoNotExposeFallbackDiagnosticsPublicly() throws {
        let packageRoot = SimulatorTestSupport.repoRootURL(filePath: #filePath)
        let modelsURL = packageRoot.appendingPathComponent("Sources/SourceCapture/WebCore/Models.swift")
        let source = try String(contentsOf: modelsURL, encoding: .utf8)

        #expect(!source.contains("public enum WebExtractionFallbackSignal"))
        #expect(!source.contains("public var fallbackSignal"))
        #expect(!source.contains("fallbackSignal: WebExtractionFallbackSignal"))
    }

    @Test
    func captureHTMLTextBuildsManifestCollectedAndCuratedNote() throws {
        let html = """
        <html lang=\"en\"><head>
        <title>Truth Boundary</title>
        <link rel=\"canonical\" href=\"https://example.com/truth-boundary\">
        <meta name=\"description\" content=\"ASK keeps truth and projections separate.\">
        <meta property=\"og:site_name\" content=\"Example Docs\">
        </head><body><article>
        <h1>Truth Boundary</h1>
        <p>ASK treats evidence and authority as canonical truth.</p>
        <p>Projections are derived and rebuilt deterministically when approved patches land.</p>
        </article></body></html>
        """
        let bundle = try WebCapture.captureHTMLText(
            html,
            pageURL: "https://example.com/truth-boundary",
            sourceID: "src_truth_boundary",
            observedAt: "2026-04-07T15:00:00Z",
            rawRelpath: defaultRawRelpath(sourceID: "src_truth_boundary", observedAt: "2026-04-07T15:00:00Z")
        )
        #expect(bundle.manifest.sourceID == "src_truth_boundary")
        #expect(bundle.manifest.finalURL == "https://example.com/truth-boundary")
        #expect(bundle.manifest.metadata["canonical_url"] == "https://example.com/truth-boundary")
        #expect(bundle.collectedSource.fragments.count >= 1)
        #expect(bundle.curatedNoteMD.contains("Truth Boundary"))
        #expect(bundle.curatedNoteMD.contains("canonical_url"))
    }

    @Test
    func browserExportSampleBuildsBundle() throws {
        let sampleURL = SimulatorTestSupport.fixtureURL(name: "browser_export_sample", withExtension: "json", filePath: #filePath)
        let bundle = try WebCapture.captureBrowserExportData(
            Data(contentsOf: sampleURL),
            sourceID: "src_browser_export",
            observedAt: "2026-04-07T15:10:00Z",
            rawRelpath: defaultRawRelpath(sourceID: "src_browser_export", observedAt: "2026-04-07T15:10:00Z")
        )
        #expect(bundle.manifest.transport == "browser_export")
        #expect(!bundle.collectedSource.fragments.isEmpty)
        #expect(bundle.curatedNoteMD.contains("## extracted"))
    }

    @Test
    func captureHTMLTextResolvesCanonicalAndKeepsStructuredContent() throws {
        let html = """
        <html lang="ko"><head>
        <title>Ignored fallback</title>
        <link rel="canonical" href="/guides/ask">
        <meta property="og:title" content="ASK Guide">
        <meta name="description" content="Structured extraction test.">
        <meta property="og:site_name" content="ASK Docs">
        </head><body>
        <nav>skip me</nav>
        <main>
        <article>
        <h1>ASK Guide</h1>
        <p>Use parser-based extraction for stable captures.</p>
        <ul>
        <li>Keep canonical URLs resolved</li>
        <li>Preserve list text for search</li>
        </ul>
        <script>console.log("ignore")</script>
        </article>
        </main></body></html>
        """
        let bundle = try WebCapture.captureHTMLText(
            html,
            pageURL: "https://example.com/docs/start",
            sourceID: "src_structured",
            observedAt: "2026-04-08T12:00:00Z",
            rawRelpath: defaultRawRelpath(sourceID: "src_structured", observedAt: "2026-04-08T12:00:00Z")
        )

        #expect(bundle.manifest.title == "ASK Guide")
        #expect(bundle.manifest.language == "ko")
        #expect(bundle.manifest.metadata["canonical_url"] == "https://example.com/guides/ask")
        #expect(bundle.manifest.metadata["site_name"] == "ASK Docs")
        #expect(bundle.manifest.metadata["description"] == "Structured extraction test.")
        #expect(bundle.curatedNoteMD.contains("# ASK Guide"))
        #expect(bundle.curatedNoteMD.contains("- Keep canonical URLs resolved"))
        #expect(!bundle.curatedNoteMD.contains("console.log"))
        #expect(bundle.collectedSource.fragments.contains { $0.text.contains("Preserve list text for search") })
    }

    @Test
    func malformedHTMLStillBuildsStructuredMarkdownAndFragments() throws {
        let html = """
        <html><head>
        <title>Parser Recovery</title>
        <link rel="canonical" href="/recovery">
        </head><body><main><article>
        <h1>Parser Recovery</h1>
        <p>Broken markup should still recover
        <p>Second paragraph survives without explicit closing tags
        <ul><li>List item one<li>List item two</ul>
        <script>console.log("ignore")</script>
        </article></main></body></html>
        """

        let bundle = try WebCapture.captureHTMLText(
            html,
            pageURL: "https://example.com/start",
            sourceID: "src_parser_recovery",
            observedAt: "2026-04-08T13:00:00Z",
            rawRelpath: defaultRawRelpath(sourceID: "src_parser_recovery", observedAt: "2026-04-08T13:00:00Z")
        )

        #expect(bundle.manifest.title == "Parser Recovery")
        #expect(bundle.manifest.metadata["canonical_url"] == "https://example.com/recovery")
        #expect(bundle.curatedNoteMD.contains("Second paragraph survives without explicit closing tags"))
        #expect(bundle.curatedNoteMD.contains("- List item one"))
        #expect(bundle.curatedNoteMD.contains("- List item two"))
        #expect(!bundle.curatedNoteMD.contains("console.log"))
        #expect(bundle.collectedSource.fragments.contains { $0.text.contains("Broken markup should still recover") })
    }

    @Test
    func captureHTMLDataRejectsInvalidUTF8() throws {
        let bytes = Data([0x3C, 0x70, 0x3E, 0xFF, 0x3C, 0x2F, 0x70, 0x3E])

        #expect(throws: ASKError.self) {
            _ = try WebCapture.captureHTMLData(
                bytes,
                url: "https://example.com/invalid-utf8",
                finalURL: "https://example.com/invalid-utf8",
                contentType: "text/html",
                statusCode: 200,
                sourceID: "src_invalid_utf8",
                observedAt: "2026-04-08T13:00:00Z",
                capturedAt: "2026-04-08T13:00:00Z",
                rawRelpath: "raw/evidence/2026-04-08/src_invalid_utf8.html",
                connector: "test",
                tags: [],
                metadata: [:],
                sourceKind: .url,
                transport: "test"
            )
        }
    }


}
