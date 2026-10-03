import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime
@testable import SourceCapture

struct StagingIntegrationTests {
    @Test
    func stagedBundleImportsIntoVaultAndCanBeApplied() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-\(UUID().uuidString)")
        let vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-vault-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: vaultRoot)
        }

        let html = """
        <html lang=\"en\"><head><title>Owner and Boundary</title></head>
        <body><article><h1>Owner and Boundary</h1>
        <p>Ax owns the ASK migration and keeps receipts explicit.</p>
        <p>The wiki is derived from approved patches and must be rebuilt deterministically.</p>
        </article></body></html>
        """
        let bundle = try WebCapture.captureHTMLText(
            html,
            pageURL: "https://example.com/owner-and-boundary",
            sourceID: "src_owner_boundary",
            observedAt: "2026-04-07T15:20:00Z",
            rawRelpath: defaultRawRelpath(sourceID: "src_owner_boundary", observedAt: "2026-04-07T15:20:00Z")
        )
        let staged = try CaptureStager.stage(bundle, using: FileSystemStagingRootProvider(root: stagingRoot))
        #expect(FileManager.default.fileExists(atPath: staged.manifestPath.path))
        _ = try ASKRuntime(root: vaultRoot).ensureVault()
        let imported = try ASKRuntime(root: vaultRoot).importCollected(staged.manifestPath)
        let collectedURL = URL(fileURLWithPath: imported.collectedPath)
        let collected = try CanonicalJSON.decode(CollectedSource.self, from: Data(contentsOf: collectedURL))
        let request = try toIngestEvidenceRequest(collected, domain: "example/staging", requestedAt: "2026-04-07T15:21:00Z")
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: plan, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-07T15:22:00Z")
        _ = try ASKRuntime(root: vaultRoot).apply(plan, receipt)
        let search = try ASKRuntime(root: vaultRoot).search("receipts explicit", limit: 5)
        #expect(!search.hits.isEmpty)
    }

    @Test
    func stagedExampleDomainBundleRetainsSourceSearchableTextParity() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-example-\(UUID().uuidString)")
        let vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-example-vault-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: vaultRoot)
        }

        let html = """
        <!doctype html><html lang=\"en\"><head><title>Example Domain</title><style>div{opacity:0.8}</style></head>
        <body><div><h1>Example Domain</h1>
        <p>This domain is for use in documentation examples without needing permission. Avoid use in operations.</p>
        <p><a href=\"https://iana.org/domains/example\">Learn more</a></p>
        </div></body></html>
        """
        let observedAt = "2026-04-08T19:10:00Z"
        let bundle = try WebCapture.captureHTMLText(
            html,
            pageURL: "https://example.com/",
            sourceID: "src_example_stage",
            observedAt: observedAt,
            rawRelpath: defaultRawRelpath(sourceID: "src_example_stage", observedAt: observedAt)
        )
        let staged = try CaptureStager.stage(bundle, using: FileSystemStagingRootProvider(root: stagingRoot))
        _ = try ASKRuntime(root: vaultRoot).ensureVault()
        let imported = try ASKRuntime(root: vaultRoot).importCollected(staged.manifestPath)
        let collected = try CanonicalJSON.decode(CollectedSource.self, from: Data(contentsOf: URL(fileURLWithPath: imported.collectedPath)))
        #expect((collected.metadata["searchable_text"] ?? "").contains("without needing permission"))

        let request = try toIngestEvidenceRequest(collected, domain: "web/example", requestedAt: "2026-04-08T19:10:10Z")
        let patch = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T19:10:20Z")
        _ = try ASKRuntime(root: vaultRoot).apply(patch, receipt)

        let sourceDoc = try ASKRuntime(root: vaultRoot).debugSourceSearchDoc(sourceID: "src_example_stage")
        #expect(sourceDoc != nil)
        let resolvedSourceDoc = try #require(sourceDoc)
        #expect(resolvedSourceDoc.body.contains("documentation examples without needing permission"))
        #expect(resolvedSourceDoc.metadata["searchable_text_version"] == searchableTextVersion)
    }

    @Test
    func stagedExampleDomainBundleRetainsMirrorAndQueryGroundingParity() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-example-\(UUID().uuidString)")
        let vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-example-vault-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: vaultRoot)
        }

        let html = """
        <!doctype html><html lang=\"en\"><head><title>Example Domain</title><style>div{opacity:0.8}</style></head>
        <body><div><h1>Example Domain</h1>
        <p>This domain is for use in documentation examples without needing permission. Avoid use in operations.</p>
        <p><a href=\"https://iana.org/domains/example\">Learn more</a></p>
        </div></body></html>
        """
        let observedAt = "2026-04-08T19:10:00Z"
        let bundle = try WebCapture.captureHTMLText(
            html,
            pageURL: "https://example.com/",
            sourceID: "src_example_stage",
            observedAt: observedAt,
            rawRelpath: defaultRawRelpath(sourceID: "src_example_stage", observedAt: observedAt)
        )
        let staged = try CaptureStager.stage(bundle, using: FileSystemStagingRootProvider(root: stagingRoot))
        _ = try ASKRuntime(root: vaultRoot).ensureVault()
        let imported = try ASKRuntime(root: vaultRoot).importCollected(staged.manifestPath)
        let collected = try CanonicalJSON.decode(CollectedSource.self, from: Data(contentsOf: URL(fileURLWithPath: imported.collectedPath)))

        let request = try toIngestEvidenceRequest(collected, domain: "web/example", requestedAt: "2026-04-08T19:10:10Z")
        let patch = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T19:10:20Z")
        _ = try ASKRuntime(root: vaultRoot).apply(patch, receipt)

        let mirrorCandidates = try ASKRuntime(root: vaultRoot).debugMirrorSearch(query: "documentation examples permission", limit: 10)
        #expect(!mirrorCandidates.isEmpty)
        #expect(mirrorCandidates.contains { $0.docKind == "source" && $0.title == "Example Domain" })

        let selection = try ASKRuntime(root: vaultRoot).debugQuerySelection(question: "what mentions permission")
        #expect(selection.failureKind == nil)
        #expect(selection.selectedHits.contains { $0.docKind == "source" && $0.title == "Example Domain" })

        let search = try ASKRuntime(root: vaultRoot).search("documentation examples permission", limit: 5)
        #expect(search.hits.contains { $0.docKind == "source" && $0.title == "Example Domain" })

        let query = try ASKRuntime(root: vaultRoot).query("what mentions permission", requestedAt: "2026-04-08T19:10:30Z")
        #expect(query.answer.contains("permission"))
        #expect(query.citations.contains { $0.title == "Example Domain" })
    }

    @Test
    func runtimeSearchKeepsRankingContract() throws {
        let vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-search-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        _ = try ASKRuntime(root: vaultRoot).ensureVault()
        let runtime = ASKRuntime(root: vaultRoot)

        let rawPayload = Data("knowledge compiler search guard source".utf8)
        let rawRelpath = "raw/evidence/2026-04-08/src_search_guard.txt"
        let rawURL = vaultRoot.appendingPathComponent(rawRelpath)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawPayload.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_search_guard",
            connector: "webcollect",
            sourceKind: .text,
            title: "Knowledge Compiler Source",
            observedAt: "2026-04-08T20:00:00Z",
            capturedAt: "2026-04-08T20:00:05Z",
            rawRelpath: rawRelpath,
            contentHash: ASKSHA256.prefixedDigest(rawPayload),
            mimeType: "text/plain",
            language: "en",
            tags: ["search", "guard"],
            metadata: ["description": "knowledge compiler search guard"],
            fragments: [
                CollectedFragment(
                    fragmentID: "frag_search_guard_001",
                    ordinal: 0,
                    locator: [:],
                    text: "knowledge compiler search guard source fragment",
                    fingerprint: nil
                )
            ]
        )
        let ingestRequest = try toIngestEvidenceRequest(collected, domain: "example/search", requestedAt: "2026-04-08T20:00:10Z")
        let ingestPatch = try planEvidenceIngest(ingestRequest).patch
        let ingestReceipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: ingestPatch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T20:00:20Z")
        _ = try ASKRuntime(root: vaultRoot).apply(ingestPatch, ingestReceipt)

        let authorityRequest = RegisterAuthorityRequest(
            version: registerAuthorityRequestVersion,
            record: AuthorityRecord(
                version: authorityRecordVersion,
                recordID: "authority_search_guard",
                recordType: "current_state",
                subjectKind: "topic",
                subjectID: "search-guard",
                factScopeKey: "knowledge_compiler_search_guard",
                approvalState: .approved,
                valueFields: ["summary": "knowledge compiler search guard"],
                effectiveFrom: "2026-04-08T20:01:00Z",
                effectiveTo: nil,
                approvedBy: "tester",
                supersedesID: nil
            ),
            requestedAt: "2026-04-08T20:01:10Z"
        )
        let authorityPatch = try runtime.planAuthorityRegistration(authorityRequest, existingRecords: []).patch
        let authorityReceipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: authorityPatch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T20:01:20Z")
        _ = try ASKRuntime(root: vaultRoot).apply(authorityPatch, authorityReceipt)

        let search = try ASKRuntime(root: vaultRoot).search("knowledge compiler", limit: 10)
        #expect(search.hits.map(\.docKind) == ["source", "authority", "claim"])
    }

    @Test
    func runtimeSearchKeepsSnippetParityWithMirrorCandidates() throws {
        let vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-search-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        _ = try ASKRuntime(root: vaultRoot).ensureVault()
        let runtime = ASKRuntime(root: vaultRoot)

        let rawPayload = Data("knowledge compiler search guard source".utf8)
        let rawRelpath = "raw/evidence/2026-04-08/src_search_guard.txt"
        let rawURL = vaultRoot.appendingPathComponent(rawRelpath)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawPayload.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_search_guard",
            connector: "webcollect",
            sourceKind: .text,
            title: "Knowledge Compiler Source",
            observedAt: "2026-04-08T20:00:00Z",
            capturedAt: "2026-04-08T20:00:05Z",
            rawRelpath: rawRelpath,
            contentHash: ASKSHA256.prefixedDigest(rawPayload),
            mimeType: "text/plain",
            language: "en",
            tags: ["search", "guard"],
            metadata: ["description": "knowledge compiler search guard"],
            fragments: [
                CollectedFragment(
                    fragmentID: "frag_search_guard_001",
                    ordinal: 0,
                    locator: [:],
                    text: "knowledge compiler search guard source fragment",
                    fingerprint: nil
                )
            ]
        )
        let ingestRequest = try toIngestEvidenceRequest(collected, domain: "example/search", requestedAt: "2026-04-08T20:00:10Z")
        let ingestPatch = try planEvidenceIngest(ingestRequest).patch
        let ingestReceipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: ingestPatch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T20:00:20Z")
        _ = try ASKRuntime(root: vaultRoot).apply(ingestPatch, ingestReceipt)

        let authorityRequest = RegisterAuthorityRequest(
            version: registerAuthorityRequestVersion,
            record: AuthorityRecord(
                version: authorityRecordVersion,
                recordID: "authority_search_guard",
                recordType: "current_state",
                subjectKind: "topic",
                subjectID: "search-guard",
                factScopeKey: "knowledge_compiler_search_guard",
                approvalState: .approved,
                valueFields: ["summary": "knowledge compiler search guard"],
                effectiveFrom: "2026-04-08T20:01:00Z",
                effectiveTo: nil,
                approvedBy: "tester",
                supersedesID: nil
            ),
            requestedAt: "2026-04-08T20:01:10Z"
        )
        let authorityPatch = try runtime.planAuthorityRegistration(authorityRequest, existingRecords: []).patch
        let authorityReceipt = try ASKRuntime(root: vaultRoot).buildReceipt(for: authorityPatch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T20:01:20Z")
        _ = try ASKRuntime(root: vaultRoot).apply(authorityPatch, authorityReceipt)

        let search = try ASKRuntime(root: vaultRoot).search("knowledge compiler", limit: 10)
        let mirrorCandidates = try ASKRuntime(root: vaultRoot).debugMirrorSearch(query: "knowledge compiler", limit: 10)
        let snippetByDocID = Dictionary(uniqueKeysWithValues: mirrorCandidates.map { ($0.docID, $0.snippet) })
        let mirroredHits = search.hits.filter { snippetByDocID[$0.docID] != nil }
        #expect(!mirroredHits.isEmpty)
        #expect(mirroredHits.allSatisfy { snippetByDocID[$0.docID] == $0.snippet })
    }

    @Test
    func captureStagerRejectsUnsafeSourceIDBeforeWritingPaths() throws {
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-stage-unsafe-\(UUID().uuidString)")
        let escapeName = "ask_escape_\(UUID().uuidString.lowercased())"
        let unsafeSourceID = "../../../../\(escapeName)"
        let escapedDirectory = stagingRoot.appendingPathComponent(".ask/collector/web/\(unsafeSourceID)", isDirectory: true).standardizedFileURL
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: escapedDirectory)
        }

        let rawBytes = Data("unsafe".utf8)
        let rawRelpath = "raw/evidence/2026/04/safe.html"
        let manifest = CollectedCaptureManifest(
            sourceID: unsafeSourceID,
            connector: "webcollect",
            transport: "html_text",
            originalURL: "https://example.com/unsafe",
            finalURL: "https://example.com/unsafe",
            title: "Unsafe Source",
            observedAt: "2026-04-08T20:00:00Z",
            capturedAt: "2026-04-08T20:00:01Z",
            rawRelpath: rawRelpath,
            noteRelpath: "notes/safe.md",
            contentHash: ASKSHA256.prefixedDigest(rawBytes),
            mimeType: "text/html",
            language: "en",
            tags: ["unsafe"],
            fragments: []
        )
        let collected = CollectedSource(
            sourceID: unsafeSourceID,
            connector: "webcollect",
            sourceKind: .url,
            title: "Unsafe Source",
            observedAt: "2026-04-08T20:00:00Z",
            capturedAt: "2026-04-08T20:00:01Z",
            rawRelpath: rawRelpath,
            contentHash: ASKSHA256.prefixedDigest(rawBytes),
            mimeType: "text/html",
            language: "en",
            tags: ["unsafe"],
            fragments: []
        )
        let bundle = WebCaptureBundle(
            manifest: manifest,
            collectedSource: collected,
            rawBytes: rawBytes,
            curatedNoteMD: "# Unsafe Source\n"
        )

        #expect(throws: ASKError.self) {
            _ = try CaptureStager.stage(bundle, using: FileSystemStagingRootProvider(root: stagingRoot))
        }
        #expect(FileManager.default.fileExists(atPath: escapedDirectory.path) == false)
    }

}
