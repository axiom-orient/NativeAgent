import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct ASKRuntimeTests {
    private enum ExtractionFixtureError: Error {
        case badHTML
    }

    private func writeUnsafeArchive(at archiveURL: URL, payload: Data) throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ask-unsafe-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let sibling = tempRoot.deletingLastPathComponent().appendingPathComponent("escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: sibling) }
        try payload.write(to: sibling, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempRoot
        process.arguments = ["-q", archiveURL.path, "../\(sibling.lastPathComponent)"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ExtractionFixtureError.badHTML
        }
    }

    private func writeSymbolicLinkArchive(at archiveURL: URL) throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ask-symlink-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let target = tempRoot.deletingLastPathComponent().appendingPathComponent("symlink-target-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: target) }
        try Data("outside".utf8).write(to: target, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("escape.txt"),
            withDestinationURL: target
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempRoot
        process.arguments = ["-q", "-y", archiveURL.path, "escape.txt"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ExtractionFixtureError.badHTML
        }
    }

    @Test
    func runtimeCanApplyAndQueryVault() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-swift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        _ = try ASKRuntime(root: tmpRoot).ensureVault()
        let rawHTML = Data("<html><body>demo</body></html>".utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-07/src_demo.html")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawHTML.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_demo",
            connector: "webcollect",
            sourceKind: .url,
            title: "Demo Source",
            observedAt: "2026-04-07T10:00:00Z",
            capturedAt: "2026-04-07T10:00:10Z",
            rawRelpath: "raw/evidence/2026-04-07/src_demo.html",
            contentHash: ASKSHA256.prefixedDigest(rawHTML),
            mimeType: "text/html",
            language: "en",
            tags: ["demo", "web"],
            metadata: ["url": "https://example.com/demo"],
            fragments: [
                CollectedFragment(fragmentID: "frag_001", ordinal: 0, locator: [:], text: "ASK is a file-backed knowledge compiler.", fingerprint: nil),
                CollectedFragment(fragmentID: "frag_002", ordinal: 1, locator: [:], text: "It keeps evidence immutable and projections derived.", fingerprint: nil),
            ]
        )

        let request = try toIngestEvidenceRequest(collected, domain: "example/web", requestedAt: "2026-04-07T10:01:00Z")
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: tmpRoot).buildReceipt(
            for: plan,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-07T10:02:00Z"
        )

        let apply = try ASKRuntime(root: tmpRoot).apply(plan, receipt)
        #expect(apply.decision == "approved")
        #expect(apply.rebuild.approvedPatchIDs.contains(plan.patchID))

        let search = try ASKRuntime(root: tmpRoot).search("knowledge compiler", limit: 5)
        #expect(!search.hits.isEmpty)

        let query = try ASKRuntime(root: tmpRoot).query("what is ASK", requestedAt: "2026-04-07T10:03:00Z")
        #expect(!query.answer.isEmpty)

        let lint = try ASKRuntime(root: tmpRoot).lint()
        #expect(lint.findingCount == 0)
    }

    @Test
    func runtimeCanSearchViaMirror() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-runtime-actor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let rawText = Data("apple silicon ask runtime actor".utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-07/src_actor.txt")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_actor",
            connector: "note",
            sourceKind: .text,
            title: "Actor Search",
            observedAt: "2026-04-07T11:00:00Z",
            capturedAt: "2026-04-07T11:00:00Z",
            rawRelpath: "raw/evidence/2026-04-07/src_actor.txt",
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["actor"],
            metadata: [:],
            fragments: [CollectedFragment(fragmentID: "frag_actor", ordinal: 0, locator: [:], text: "Ask runtime client uses actor isolation for iOS coordination.", fingerprint: nil)]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "example/actor", requestedAt: "2026-04-07T11:01:00Z")
        let plan = try planEvidenceIngest(request).patch
        let receipt = try runtime.buildReceipt(
            for: plan,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-07T11:02:00Z"
        )
        _ = try runtime.apply(plan, receipt)
        let result = try runtime.search("actor isolation", limit: 5)
        #expect(!result.hits.isEmpty)
        let sourceRowValue = try runtime.debugSourceSearchDoc(sourceID: "src_actor")
        let sourceRow = try #require(sourceRowValue)
        let sourceHit = try #require(result.hits.first { $0.docID == sourceRow.docID })
        #expect(sourceHit.snippet == firstLine(sourceRow.body, maxLen: 180))

        let corruptPatchDir = tmpRoot.appendingPathComponent(".ask/journal/patches/zz_corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptPatchDir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: corruptPatchDir.appendingPathComponent("patch.json"))

        // A stale derived mirror must not conceal malformed canonical input.
        #expect(throws: (any Error).self) {
            _ = try runtime.search("actor isolation", limit: 5)
        }
    }

    @Test
    func sourceReceiptsRejectDuplicateIDs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-source-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ASKRuntime(root: root)
        _ = try runtime.ensureVault()

        #expect(throws: ASKError.validation("source receipt IDs must be unique")) {
            try runtime.sourceReceipts(sourceIDs: ["src_duplicate", "src_duplicate"])
        }
    }

    @Test
    func lintKeepsSupportedUnlinkedProjectionClean() throws {
        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .currentSnapshot,
            projectionSpace: .wiki,
            subjectKind: "project",
            subjectID: "ask",
            authorityIDs: ["authority_owner"],
            sourceIDs: [],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "current/project/ask",
            title: "Current status of ASK",
            bodyMD: "# Current status\n\nASK is supported by the owner authority.",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T12:00:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        store.replaceProjectionWrites(
            slug: document.slug,
            writes: [ProjectionWrite(slug: document.slug, state: .accepted, document: document)]
        )

        let lint = ASKRuntimeLinter.lint(store)
        #expect(!lint.findings.contains { $0.kind == "orphan_projection" })
    }

    @Test
    func queryEventAcceptsEquivalentLegacyJSONFormatting() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-legacy-event-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()
        let requestedAt = "2026-04-08T12:30:00Z"
        let question = "legacy event formatting"
        let logID = stableID(prefix: "log", parts: ["query", requestedAt, question])
        let eventURL = tmpRoot.appendingPathComponent(".ask/journal/events/\(logID).json")
        try Data("""
        {
          "log_id": "\(logID)",
          "occurred_at": "\(requestedAt)",
          "op_kind": "query",
          "summary": "query executed: \(question)"
        }
        """.utf8).write(to: eventURL, options: .atomic)

        let result = try runtime.query(question, requestedAt: requestedAt)
        #expect(result.answer == "No grounded result found in the local vault.")
    }

    @Test
    func vaultExportRoundTripIsSupported() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-archive-\(UUID().uuidString)")
        let importRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-archive-import-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tmpRoot)
            try? FileManager.default.removeItem(at: importRoot)
        }

        _ = try ASKRuntime(root: tmpRoot).ensureVault()
        let rawText = Data("archive round trip source".utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-07/src_archive.txt")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_archive",
            connector: "note",
            sourceKind: .text,
            title: "Archive Source",
            observedAt: "2026-04-07T12:00:00Z",
            capturedAt: "2026-04-07T12:00:00Z",
            rawRelpath: "raw/evidence/2026-04-07/src_archive.txt",
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["archive"],
            metadata: [:],
            fragments: [CollectedFragment(fragmentID: "frag_archive", ordinal: 0, locator: [:], text: "archive round trip works", fingerprint: nil)]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "example/archive", requestedAt: "2026-04-07T12:01:00Z")
        let plan = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: tmpRoot).buildReceipt(
            for: plan, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-07T12:02:00Z")
        _ = try ASKRuntime(root: tmpRoot).apply(plan, receipt)

        let archiveURL = tmpRoot.appendingPathComponent("export.zip")
        try ASKRuntime(root: tmpRoot).exportVault(to: archiveURL)
        let archiveData = try Data(contentsOf: archiveURL)
        #expect(!archiveData.isEmpty)
        let archivePaths = try archiveEntryNames(at: archiveURL)
        #expect(archivePaths.contains("export-manifest.json"))
        #expect(archivePaths.allSatisfy { !$0.hasPrefix("mirror/") })

        let importedState = try ASKRuntime(root: importRoot).importVault(from: archiveURL)
        #expect(importedState.approvedPatchIDs.contains(plan.patchID))
        let importedSearch = try ASKRuntime(root: importRoot).search("archive round trip", limit: 5)
        #expect(importedSearch.hits.contains { $0.snippet.contains("archive round trip") || $0.title.contains("Archive") })

    }

    @Test
    func archiveListingDrainsLargeToolOutput() throws {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-large-listing-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let entries = (0..<3_000).map { index in
            ("entries/\(String(format: "%05d", index))-\(String(repeating: "x", count: 24)).txt", Data())
        }
        try writeArchiveEntries(entries, to: archiveURL)

        let paths = try archiveEntryNames(at: archiveURL)
        #expect(paths.filter { $0.hasSuffix(".txt") }.count == entries.count)
    }

    @Test
    func vaultImportRejectsUnsafeArchivePaths() throws {
        let importRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-unsafe-import-\(UUID().uuidString)")
        let archiveURL = importRoot.deletingLastPathComponent().appendingPathComponent("unsafe-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: importRoot)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let payload = Data("unsafe".utf8)
        try writeUnsafeArchive(at: archiveURL, payload: payload)

        #expect(throws: Error.self) {
            _ = try ASKRuntime(root: importRoot).importVault(from: archiveURL)
        }
    }

    @Test
    func vaultImportRejectsSymbolicLinkArchiveEntries() throws {
        let importRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-symlink-import-\(UUID().uuidString)")
        let archiveURL = importRoot.deletingLastPathComponent().appendingPathComponent("symlink-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: importRoot)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        try writeSymbolicLinkArchive(at: archiveURL)

        do {
            _ = try ASKRuntime(root: importRoot).importVault(from: archiveURL)
            Issue.record("Expected symbolic-link archive entry to be rejected")
        } catch {
            #expect(String(describing: error).contains("symbolic link"))
            #expect(String(describing: error).contains("escape.txt"))
        }
    }

    @Test
    func runtimeCanRemoveProjectionViaPublicAPI() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let metadata = ProjectionMetadata(
            projectionKind: .entityOverview,
            projectionSpace: .wiki,
            subjectKind: "device",
            subjectID: "iphone15",
            authorityIDs: [],
            sourceIDs: ["src_remove"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "wiki/device-threshold",
            title: "Battery Threshold",
            bodyMD: "Battery threshold is 85 percent for travel days.",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T08:00:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        let refresh = RefreshProjectionRequest(
            version: refreshProjectionRequestVersion,
            requestedAt: "2026-04-08T08:00:00Z",
            trigger: "seed",
            proposedWrites: [ProjectionWrite(slug: document.slug, state: .accepted, document: document)]
        )
        let patch = try runtime.planProjectionRefresh(refresh).patch
        let receipt = try runtime.buildReceipt(
            for: patch,
            decision: .approved,
            decidedBy: "tester",
            decidedAt: "2026-04-08T08:00:01Z"
        )
        _ = try runtime.apply(patch, receipt)

        #expect(try runtime.snapshot().visibleProjections["wiki/device-threshold"] != nil)

        _ = try runtime.removeProjection(
            slug: "wiki/device-threshold",
            requestedAt: "2026-04-08T08:01:00Z",
            decidedBy: "tester",
            decidedAt: "2026-04-08T08:01:01Z"
        )

        let snapshot = try runtime.snapshot()
        #expect(snapshot.visibleProjections["wiki/device-threshold"] == nil)

        let search = try runtime.search("travel days", limit: 5)
        #expect(search.hits.allSatisfy { $0.projectionSlug != "wiki/device-threshold" })
    }

    @Test
    func sourceTitleAndFragmentTextBecomeSearchable() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-source-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        _ = try ASKRuntime(root: tmpRoot).ensureVault()
        let rawHTML = Data("""
        <html><body><main><h1>Example Domain</h1><p>This domain is for use in documentation examples without needing permission.</p></main></body></html>
        """.utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-08/src_example.html")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawHTML.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_example",
            connector: "webcollect",
            sourceKind: .url,
            title: "Example Domain",
            observedAt: "2026-04-08T09:00:00Z",
            capturedAt: "2026-04-08T09:00:05Z",
            rawRelpath: "raw/evidence/2026-04-08/src_example.html",
            contentHash: ASKSHA256.prefixedDigest(rawHTML),
            mimeType: "text/html",
            language: "en",
            tags: ["web"],
            metadata: [
                "canonical_url": "https://example.com/",
                "final_url": "https://example.com/",
                "description": "Example Domain page"
            ],
            fragments: [
                CollectedFragment(fragmentID: "frag_example_001", ordinal: 0, locator: [:], text: "This domain is for use in documentation examples without needing permission.", fingerprint: nil)
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "web/example", requestedAt: "2026-04-08T09:00:10Z")
        let patch = try planEvidenceIngest(request).patch
        let receipt = try ASKRuntime(root: tmpRoot).buildReceipt(
            for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T09:00:20Z")
        _ = try ASKRuntime(root: tmpRoot).apply(patch, receipt)

        let titleSearch = try ASKRuntime(root: tmpRoot).search("Example Domain", limit: 5)
        #expect(titleSearch.hits.contains { $0.docKind == "source" && $0.title == "Example Domain" })

        let bodySearch = try ASKRuntime(root: tmpRoot).search("documentation examples permission", limit: 5)
        #expect(bodySearch.hits.contains { $0.docKind == "source" && $0.title == "Example Domain" })

        let contentQuery = try ASKRuntime(root: tmpRoot).query("what mentions permission", requestedAt: "2026-04-08T09:00:30Z")
        #expect(contentQuery.answer.contains("permission"))
        #expect(contentQuery.citations.contains { $0.title == "Example Domain" })
    }

    @Test
    func stagedAuthorityConflictAppearsInReviewQueue() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-review-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let existing = AuthorityRecord(
            version: authorityRecordVersion,
            recordID: "authority_existing",
            recordType: "current_state",
            subjectKind: "project",
            subjectID: "kapasi",
            factScopeKey: "current_battery_policy",
            approvalState: .approved,
            valueFields: ["threshold": "80"],
            effectiveFrom: "2026-04-01T00:00:00Z",
            effectiveTo: nil,
            approvedBy: "human",
            supersedesID: nil
        )
        let request = RegisterAuthorityRequest(
            version: registerAuthorityRequestVersion,
            record: AuthorityRecord(
                version: authorityRecordVersion,
                recordID: "authority_candidate",
                recordType: "current_state",
                subjectKind: "project",
                subjectID: "kapasi",
                factScopeKey: "current_battery_policy",
                approvalState: .approved,
                valueFields: ["threshold": "85"],
                effectiveFrom: "2026-04-08T09:00:00Z",
                effectiveTo: nil,
                approvedBy: "human",
                supersedesID: nil
            ),
            requestedAt: "2026-04-08T09:00:10Z"
        )
        let plan = try runtime.planAuthorityRegistration(request, existingRecords: [existing]).patch
        try runtime.stage(plan)

        let queue = try runtime.reviewQueue()
        #expect(queue.pendingCount > 0)
        #expect(queue.items.contains { $0.reviewKind == "ambiguous_authority_change" })
    }

    @Test
    func promoteSourceToWikiCreatesVisibleSummaryProjection() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-promote-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let rawHTML = Data("""
        <html><body><main><h1>Example Domain</h1><p>This domain is for use in documentation examples without needing permission.</p></main></body></html>
        """.utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-08/src_example_promote.html")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawHTML.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_example_promote",
            connector: "webcollect",
            sourceKind: .url,
            title: "Example Domain",
            observedAt: "2026-04-08T10:00:00Z",
            capturedAt: "2026-04-08T10:00:05Z",
            rawRelpath: "raw/evidence/2026-04-08/src_example_promote.html",
            contentHash: ASKSHA256.prefixedDigest(rawHTML),
            mimeType: "text/html",
            language: "en",
            tags: ["web"],
            metadata: ["final_url": "https://example.com/"],
            fragments: [
                CollectedFragment(fragmentID: "frag_promote_001", ordinal: 0, locator: [:], text: "This domain is for use in documentation examples without needing permission.", fingerprint: nil)
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "web/example", requestedAt: "2026-04-08T10:00:10Z")
        let patch = try runtime.planEvidenceIngest(request).patch
        let receipt = try runtime.buildReceipt(for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T10:00:20Z")
        _ = try runtime.apply(patch, receipt)

        _ = try runtime.promoteSourceToWiki(
            sourceID: "src_example_promote",
            slug: "wiki/example-domain",
            title: "Example Domain",
            requestedAt: "2026-04-08T10:01:00Z",
            decidedBy: "tester",
            decidedAt: "2026-04-08T10:01:01Z",
            bodySeed: "Summarize the public purpose of this page."
        )

        let document = try runtime.projectionDocument(slug: "wiki/example-domain")
        #expect(document != nil)
        let resolvedDocument = try #require(document)
        #expect(resolvedDocument.metadata.projectionKind == .sourceSummary)
        #expect(resolvedDocument.bodyMD.contains("documentation examples"))
    }

    @Test
    func importFailurePreservesExistingVaultContents() throws {
        let vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-import-preserve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        _ = try ASKRuntime(root: vaultRoot).ensureVault()
        let sentinel = vaultRoot.appendingPathComponent("keep.txt")
        try "keep".data(using: .utf8)!.write(to: sentinel)

        let archiveURL = vaultRoot.deletingLastPathComponent().appendingPathComponent("invalid-import-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let payload = Data("payload".utf8)
        try writeArchiveEntries([("notes.txt", payload)], to: archiveURL)

        #expect(throws: Error.self) {
            _ = try ASKRuntime(root: vaultRoot).importVault(from: archiveURL)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }


    @Test
    func compileSourceProjectionSetAutoExtractsStructuredSeedsConservatively() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-auto-compile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let rawText = Data("ASK Runtime uses Foundation Models for on-device summaries. Foundation Models keeps the runtime grounded.".utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-08/src_auto.txt")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_auto",
            connector: "note",
            sourceKind: .text,
            title: "ASK Runtime with Foundation Models",
            observedAt: "2026-04-08T10:00:00Z",
            capturedAt: "2026-04-08T10:00:00Z",
            rawRelpath: "raw/evidence/2026-04-08/src_auto.txt",
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["on-device-llm"],
            metadata: [:],
            fragments: [
                CollectedFragment(
                    fragmentID: "frag_auto_001",
                    ordinal: 0,
                    locator: ["heading": "Foundation Models"],
                    text: "ASK Runtime uses Foundation Models for on-device summaries.",
                    fingerprint: nil
                ),
                CollectedFragment(
                    fragmentID: "frag_auto_002",
                    ordinal: 1,
                    locator: ["heading": "Runtime Integration"],
                    text: "Foundation Models keeps ASK Runtime grounded on device.",
                    fingerprint: nil
                ),
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "example/auto", requestedAt: "2026-04-08T10:01:00Z")
        let ingestPatch = try runtime.planEvidenceIngest(request).patch
        let ingestReceipt = try runtime.buildReceipt(for: ingestPatch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T10:02:00Z")
        _ = try runtime.apply(ingestPatch, ingestReceipt)

        let authority = AuthorityRecord(
            version: authorityRecordVersion,
            recordID: "auth_auto_runtime",
            recordType: "runtime_snapshot",
            subjectKind: "runtime",
            subjectID: "ask-runtime",
            factScopeKey: "runtime_state",
            approvalState: .approved,
            valueFields: ["name": "ASK Runtime", "state": "grounded"],
            effectiveFrom: "2026-04-08T10:02:30Z",
            effectiveTo: nil,
            approvedBy: "tester",
            supersedesID: nil
        )
        let authorityRequest = RegisterAuthorityRequest(
            version: registerAuthorityRequestVersion,
            record: authority,
            requestedAt: "2026-04-08T10:02:30Z"
        )
        let authorityPatch = try runtime.planAuthorityRegistration(authorityRequest, existingRecords: []).patch
        let authorityReceipt = try runtime.buildReceipt(for: authorityPatch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T10:02:31Z")
        _ = try runtime.apply(authorityPatch, authorityReceipt)

        _ = try runtime.compileSourceProjectionSet(
            sourceID: "src_auto",
            sourceSlug: "ask-runtime-foundation-models",
            sourceTitle: "ASK Runtime with Foundation Models",
            requestedAt: "2026-04-08T10:03:00Z",
            decidedBy: "tester",
            decidedAt: "2026-04-08T10:03:01Z"
        )

        let sourceDoc = try #require(try runtime.projectionDocument(slug: "sources/ask-runtime-foundation-models"))
        let entityDoc = try #require(try runtime.projectionDocument(slug: "entities/ask-runtime"))
        let topicDoc = try #require(try runtime.projectionDocument(slug: "topics/on-device-llm"))
        let currentDoc = try #require(try runtime.projectionDocument(slug: "current/ask-runtime"))

        #expect(sourceDoc.bodyMD.contains("[[entities/ask-runtime|ASK Runtime]]"))
        #expect(entityDoc.bodyMD.contains("[[sources/ask-runtime-foundation-models|ASK Runtime with Foundation Models]]"))
        #expect(topicDoc.metadata.projectionKind == .topicOverview)
        #expect(currentDoc.metadata.authorityIDs == ["auth_auto_runtime"])
        #expect(currentDoc.bodyMD.contains("Approved authority scopes: runtime_state"))
    }


    @Test
    func compileSourceProjectionSetCreatesCanonicalPagesAndLinks() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-projection-set-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let rawText = Data("ASK is a mobile-first file compiler. It keeps markdown pages interlinked.".utf8)
        let rawURL = tmpRoot.appendingPathComponent("raw/evidence/2026-04-08/src_compile.txt")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawText.write(to: rawURL)

        let collected = CollectedSource(
            sourceID: "src_compile",
            connector: "note",
            sourceKind: .text,
            title: "Compile Source",
            observedAt: "2026-04-08T11:00:00Z",
            capturedAt: "2026-04-08T11:00:00Z",
            rawRelpath: "raw/evidence/2026-04-08/src_compile.txt",
            contentHash: ASKSHA256.prefixedDigest(rawText),
            mimeType: "text/plain",
            language: "en",
            tags: ["wiki"],
            metadata: [:],
            fragments: [
                CollectedFragment(fragmentID: "frag_compile", ordinal: 0, locator: [:], text: "ASK is a mobile-first file compiler. It keeps markdown pages interlinked.", fingerprint: nil)
            ]
        )
        let request = try toIngestEvidenceRequest(collected, domain: "example/compile", requestedAt: "2026-04-08T11:01:00Z")
        let patch = try runtime.planEvidenceIngest(request).patch
        let receipt = try runtime.buildReceipt(for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T11:02:00Z")
        _ = try runtime.apply(patch, receipt)

        _ = try runtime.compileSourceProjectionSet(
            sourceID: "src_compile",
            sourceSlug: "compile-source",
            sourceTitle: "Compile Source",
            requestedAt: "2026-04-08T11:03:00Z",
            decidedBy: "tester",
            decidedAt: "2026-04-08T11:03:01Z",
            sourceBodySeed: "This source should connect the canonical wiki pages.",
            related: [
                WikiProjectionSeed(
                    slug: "ask",
                    title: "ASK",
                    projectionKind: .entityOverview,
                    subjectKind: "project",
                    subjectID: "ask",
                    authorityIDs: [],
                    claimIDs: [],
                    bodySeed: "ASK is the entity page."
                ),
                WikiProjectionSeed(
                    slug: "mobile-file-first",
                    title: "Mobile File First",
                    projectionKind: .topicOverview,
                    subjectKind: "topic",
                    subjectID: "mobile-file-first",
                    authorityIDs: [],
                    claimIDs: [],
                    bodySeed: "This topic tracks the file-first design."
                ),
                WikiProjectionSeed(
                    slug: "ask-runtime",
                    title: "ASK Runtime",
                    projectionKind: .currentSnapshot,
                    subjectKind: "runtime",
                    subjectID: "ask-runtime",
                    authorityIDs: ["auth_current"],
                    claimIDs: [],
                    bodySeed: "This page tracks the current runtime state."
                ),
            ]
        )

        let sourceDoc = try #require(try runtime.projectionDocument(slug: "sources/compile-source"))
        let entityDoc = try #require(try runtime.projectionDocument(slug: "entities/ask"))
        let topicDoc = try #require(try runtime.projectionDocument(slug: "topics/mobile-file-first"))
        let currentDoc = try #require(try runtime.projectionDocument(slug: "current/ask-runtime"))

        #expect(sourceDoc.bodyMD.contains("[[entities/ask|ASK]]"))
        #expect(entityDoc.bodyMD.contains("[[sources/compile-source|Compile Source]]"))
        #expect(topicDoc.metadata.projectionKind == .topicOverview)
        #expect(currentDoc.metadata.projectionKind == .currentSnapshot)

        let state = try runtime.snapshot()
        #expect(state.mirrorCounts["page_links", default: 0] >= 6)
        #expect(FileManager.default.fileExists(atPath: tmpRoot.appendingPathComponent("wiki/sources/compile-source.md").path))
        #expect(FileManager.default.fileExists(atPath: tmpRoot.appendingPathComponent("wiki/entities/ask.md").path))
        #expect(FileManager.default.fileExists(atPath: tmpRoot.appendingPathComponent("wiki/topics/mobile-file-first.md").path))
        #expect(FileManager.default.fileExists(atPath: tmpRoot.appendingPathComponent("wiki/current/ask-runtime.md").path))
    }

    @Test
    func searchPrefersCanonicalProjectionOverQueryArtifact() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-ranking-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let runtime = ASKRuntime(root: tmpRoot)
        _ = try runtime.ensureVault()

        let canonicalMetadata = ProjectionMetadata(
            projectionKind: .currentSnapshot,
            projectionSpace: .wiki,
            subjectKind: "runtime",
            subjectID: "ask-runtime",
            authorityIDs: ["auth_current"],
            sourceIDs: ["src_rank"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var canonical = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "current/ask-runtime",
            title: "ASK Runtime",
            bodyMD: "The current runtime is a mobile-first knowledge compiler.",
            metadata: canonicalMetadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T12:00:00Z"
        )
        canonical.generatedFromHash = projectionDocumentHash(canonical)

        let queryMetadata = ProjectionMetadata(
            projectionKind: .queryArtifact,
            projectionSpace: .wiki,
            subjectKind: "query",
            subjectID: "q_rank",
            authorityIDs: [],
            sourceIDs: ["src_rank"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var queryArtifact = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "queries/runtime-ranking",
            title: "Runtime Ranking Query",
            bodyMD: "This query artifact also says mobile-first knowledge compiler.",
            metadata: queryMetadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T12:00:10Z"
        )
        queryArtifact.generatedFromHash = projectionDocumentHash(queryArtifact)

        let refresh = RefreshProjectionRequest(
            version: refreshProjectionRequestVersion,
            requestedAt: "2026-04-08T12:01:00Z",
            trigger: "seed",
            proposedWrites: [
                ProjectionWrite(slug: canonical.slug, state: .accepted, document: canonical),
                ProjectionWrite(slug: queryArtifact.slug, state: .accepted, document: queryArtifact),
            ]
        )
        let patch = try runtime.planProjectionRefresh(refresh).patch
        let receipt = try runtime.buildReceipt(for: patch, decision: .approved, decidedBy: "tester", decidedAt: "2026-04-08T12:01:01Z")
        _ = try runtime.apply(patch, receipt)

        let result = try runtime.search("mobile-first knowledge compiler", limit: 5)
        #expect(result.hits.first?.projectionSlug == "current/ask-runtime")
    }

    @Test
    func searchRankingUsesDatasetTimestampsInsteadOfWallClock() throws {
        let rows = [
            SearchDocRow(
                docID: "newer",
                docKind: "projection",
                subjectKind: "runtime",
                subjectID: "newer",
                projectionSlug: "current/newer",
                title: "Runtime Freshness",
                body: "runtime freshness ranking",
                metadata: [
                    "generated_at": "2020-01-15T00:00:00Z",
                    "is_canonical": "1",
                    "authority_state": AuthorityState.approved.rawValue,
                ]
            ),
            SearchDocRow(
                docID: "older",
                docKind: "projection",
                subjectKind: "runtime",
                subjectID: "older",
                projectionSlug: "current/older",
                title: "Runtime Freshness",
                body: "runtime freshness ranking",
                metadata: [
                    "generated_at": "2020-01-01T00:00:00Z",
                    "is_canonical": "1",
                    "authority_state": AuthorityState.approved.rawValue,
                ]
            ),
        ]

        let ranked = debugSearchRankingScores(rows: rows, query: "runtime freshness ranking", limit: 2)

        #expect(ranked.map(\.docID) == ["newer", "older"])
        #expect(ranked[0].score > ranked[1].score)
    }

}
