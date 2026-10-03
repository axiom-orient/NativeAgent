import ASKApplication
import DocumentCore
import DocumentRuntime
import DocumentUI
import EvidenceIndex
import Foundation
import HTMLDocument
import HWPDocument
import KnowledgeCore
import KnowledgeHealth
import KnowledgePresentation
import KnowledgeRuntime
import MarkdownWiki
import PageIndex
import SourceCapture
import ASKTutor
import WorkWiki

@main
enum DeepConsumer {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "DeepConsumer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-deep-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func main() async {
        do {
            let digest = ASKSHA256.hexDigest(Data("ASK".utf8))
            try require(digest == "6d6125cc4538aaec9dbef490ab1091a6cb4af5348f96a5cb0bfeeeda6edfebbe", "SHA-256 differs from known digest")
            print("KnowledgeCore PASS sha256=\(digest.prefix(12))")

            let source = "Hello [cite](ask-cite://paper-1) [tensor](ask-entity://tensor)"
            let document = ASKPageMarkdownCompiler().compile(markdown: source, documentID: .init("probe-doc"), sourceID: .init("probe-source"))
            let rendered = try await ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine()).render(
                document: document,
                configuration: .init(width: 200, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
            )
            let html = ASKHTMLSnapshotExporter().export(document: rendered)
            try require(!document.blocks.isEmpty && html.contains("data-semantic-role=\"citation\""), "compiled citation was not rendered")
            print("DocumentCore PASS blocks=\(document.blocks.count) htmlCitation=\(html.contains("data-semantic-role=\"citation\""))")

            let dirty = try Soup.parseHTML("<article><h1>Probe</h1><p>safe</p><script>bad()</script></article>")
            let cleaned = HTMLCleaner(.basic()).clean(dirty).normalizedText
            try require(!cleaned.contains("bad") && cleaned.contains("safe"), "HTML cleaning failed")
            print("HTMLDocument PASS scriptRemoved=\(!cleaned.contains("bad"))")

            let wikiRoot = try temporaryDirectory("wiki")
            defer { try? FileManager.default.removeItem(at: wikiRoot) }
            let wiki = ASKMarkdownWikiService()
            _ = try wiki.bootstrap(root: wikiRoot)
            _ = try wiki.createWikiPage(root: wikiRoot, relativePath: "wiki/probe.md", content: "# Probe\n\nVerified")
            let wikiText = try wiki.readText(root: wikiRoot, relativePath: "wiki/probe.md")
            try require(wikiText.contains("Verified"), "written wiki content did not round-trip")
            print("MarkdownWiki PASS readBytes=\(wikiText.utf8.count)")

            let indexRoot = try temporaryDirectory("index")
            defer { try? FileManager.default.removeItem(at: indexRoot) }
            let markdownURL = indexRoot.appendingPathComponent("source.md")
            try "# Root\n\nEvidence body".write(to: markdownURL, atomically: true, encoding: .utf8)
            let index = try ASKPageIndexExtension(workspaceURL: indexRoot)
            let entry = try await index.ingest(sourceAt: markdownURL)
            let catalog = try await index.catalog(sourceID: entry.sourceID)
            try require(!catalog.isEmpty, "ingested source has no catalog")
            print("PageIndex PASS catalogEntries=\(catalog.count)")
            let evidenceIndex = try ASKEvidenceIndex(workspaceURL: indexRoot)
            let evidenceHits = try await evidenceIndex.search(ASKEvidenceQuery(text: "Evidence body"))
            try require(!evidenceHits.isEmpty, "ingested evidence was not searchable")
            print("EvidenceIndex PASS hits=\(evidenceHits.count)")

            let capture = try WebCapture.captureHTMLText(
                "<html><head><title>Capture</title></head><body><article><h1>Capture</h1><p>Collected input.</p></article></body></html>",
                pageURL: "https://example.com/probe",
                sourceID: "src_probe",
                observedAt: "2026-07-26T00:00:00Z",
                rawRelpath: "raw/probe.html"
            )
            try require(capture.manifest.title == "Capture", "capture lost its title")
            print("SourceCapture PASS title=\(capture.manifest.title)")

            let selection = ASKPageRuntimePlanner().select(availableKinds: [.markdown, .fullHTML])
            try require(selection?.selectedKind == .fullHTML, "runtime did not select the preferred available artifact")
            print("DocumentRuntime PASS selected=\(selection?.selectedKind.rawValue ?? "none")")

            guard let fixturePath = ProcessInfo.processInfo.environment["ASK_HWPX_FIXTURE"] else {
                throw NSError(domain: "DeepConsumer", code: 1, userInfo: [NSLocalizedDescriptionKey: "ASK_HWPX_FIXTURE is required"])
            }
            let fixtureURL = URL(fileURLWithPath: fixturePath)
            let hwpx = try ASKPageHWPNativeParser().parse(fileURL: fixtureURL)
            let emptyRejected: Bool
            do { _ = try ASKPageHWPNativeParser().parse(data: Data()); emptyRejected = false } catch { emptyRejected = true }
            try require(!hwpx.paragraphs.isEmpty && emptyRejected, "HWPX parse or invalid-input rejection failed")
            print("HWPDocument PASS format=\(hwpx.format.rawValue) paragraphs=\(hwpx.paragraphs.count) emptyRejected=\(emptyRejected)")

            let vaultRoot = try temporaryDirectory("vault")
            defer { try? FileManager.default.removeItem(at: vaultRoot) }
            let runtime = ASKRuntime(root: vaultRoot)
            try runtime.ensureVault()
            print("KnowledgeRuntime PASS files=\(try runtime.snapshot().fileCount)")
            let health = try await ASKKnowledgeStorageHealthIntegration
                .makeStorageHealthRuntime(vaultURL: vaultRoot, evidenceIndexURL: indexRoot)
                .healthReport()
            try require(health.derivedFreshness.count == 2, "health report omitted a derived component")
            print("KnowledgeHealth PASS components=\(health.derivedFreshness.count)")

            let application = ASKApplicationRuntime()
            let resources = ASKApplicationConfiguration(vaultURL: vaultRoot, evidenceIndexURL: indexRoot)
            let lease = try await application.beginMutation(actionID: "deep-consumer", configuration: resources)
            let active = await application.isActiveMutation(lease, protecting: [vaultRoot, indexRoot])
            try require(active, "application did not reserve its resource roots")
            let released = await application.finishMutation(lease)
            try require(released, "application did not release its mutation lease")
            print("ASKApplication PASS mutationLeaseReleased=true")

            let tutorRoot = try temporaryDirectory("tutor")
            defer { try? FileManager.default.removeItem(at: tutorRoot) }
            let store = JSONFileTutorStore(rootURL: tutorRoot)
            try await store.ensureRoot()
            let learner = LearnerProfile(learnerID: "deep-learner", displayName: "Probe", updatedAt: "2026-07-26T00:00:00Z")
            try await store.saveLearner(learner)
            let reopened = JSONFileTutorStore(rootURL: tutorRoot)
            let loaded = try await reopened.loadLearner(learnerID: learner.learnerID)
            try require(loaded == learner, "tutor learner did not survive store reopen")
            print("ASKTutor PASS learnerSaveAndReopen=true")

            let workRoot = try temporaryDirectory("workwiki")
            defer { try? FileManager.default.removeItem(at: workRoot) }
            let quickStart = try await ASKWorkWikiQuickStartRunner().run(
                .init(workspaceURL: workRoot, requestedAt: "2026-07-26T00:00:00Z", decidedBy: "probe", reason: "deep consumer probe")
            )
            try require(quickStart.indexedCount > 0, "quick-start indexed no sources")
            print("WorkWiki PASS status=\(quickStart.status) indexed=\(quickStart.indexedCount)")
            let presentation = try ASKKnowledgeWorkspaceRuntime(
                workspace: ASKKnowledgeWorkspacePaths(rootURL: workRoot),
                knowledgeRootURL: URL(fileURLWithPath: quickStart.vaultPath)
            )
            let reading = try await presentation.loadProjectionReadingContext(slug: quickStart.projectionSlug)
            try require(reading.presentation.projection.slug == quickStart.projectionSlug, "projection reading context differs from committed projection")
            print("KnowledgePresentation PASS loadedProjection=\(reading.presentation.projection.slug)")

            let viewer = await MainActor.run { ASKPageHWPNativeTextViewer(documentURL: fixtureURL) }
            try require(viewer.documentURL == fixtureURL, "viewer changed the document URL")
            print("DocumentUI CONSTRUCTION_PASS viewConstructed=\(viewer.documentURL == fixtureURL)")
        } catch {
            print("DEEP FAIL error=\(error)")
            Foundation.exit(1)
        }
    }
}
