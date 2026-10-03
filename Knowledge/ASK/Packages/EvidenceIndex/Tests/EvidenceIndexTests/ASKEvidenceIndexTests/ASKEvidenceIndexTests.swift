import XCTest
@testable import EvidenceIndex
import PageIndex

final class ASKEvidenceIndexTests: XCTestCase, @unchecked Sendable {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMarkdown(_ content: String, named fileName: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    private func indexMarkdown(_ url: URL, workspace: URL) async throws -> SourceIndexManifestEntry {
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()
        let artifact = try await builder.buildArtifact(from: url, options: options)
        let store = try SourceIndexStore(workspaceURL: workspace)
        return try await store.put(artifact)
    }

    func testMetadataExtractorParsesFrontmatterLists() {
        let markdown = """
        ---
        topic: customer-a-onboarding
        stage: prove
        status: active
        updated_at: 2026-04-20
        scope: work
        tags:
          - onboarding
          - customer-a
        source_refs: [raw/a.md, raw/b.md]
        ---

        # Proof
        body
        """
        let frontmatter = ASKEvidenceMetadataExtractor.parseFrontmatter(markdown: markdown)
        XCTAssertEqual(frontmatter.scalar("topic"), "customer-a-onboarding")
        XCTAssertEqual(frontmatter.scalar("stage"), "prove")
        XCTAssertEqual(frontmatter.list("tags"), ["onboarding", "customer-a"])
        XCTAssertEqual(frontmatter.list("source_refs"), ["raw/a.md", "raw/b.md"])
    }

    func testTieOrderingIsStableForEquivalentSourcePaths() throws {
        let range = try SourceRange(space: .line, start: 1, end: 1)
        func hit(sourceID: String, sourcePath: String?) -> ASKEvidenceHit {
            ASKEvidenceHit(
                sourceID: SourceID(sourceID),
                nodeID: "node",
                title: "same",
                sectionPath: [],
                range: range,
                excerpt: "same",
                score: 1,
                metadata: ASKEvidenceMetadata(
                    sourceID: SourceID(sourceID),
                    sourcePath: sourcePath,
                    documentTitle: "same",
                    scope: .work,
                    kind: .source
                ),
                freshness: .ok
            )
        }

        let nilPath = hit(sourceID: "src_b", sourcePath: nil)
        let emptyPath = hit(sourceID: "src_a", sourcePath: "")
        let forward = ASKEvidenceQueryEngine.sortedHits([nilPath, emptyPath])
        let reverse = ASKEvidenceQueryEngine.sortedHits([emptyPath, nilPath])

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.map(\.sourceID.rawValue), ["src_a", "src_b"])
    }

    func testSearchFindsMetadataFilteredEvidence() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let target = try writeMarkdown(
            """
            ---
            topic: customer-a-onboarding
            stage: prove
            scope: work
            status: active
            tags:
              - onboarding
            ---

            # Evidence
            Customer A onboarding blocker was reproduced in the staging environment.

            ## Result
            Retry path fixed the onboarding blocker.
            """,
            named: "work-wiki/wip/prove/customer-a-onboarding.md",
            to: sourceRoot
        )
        _ = try await indexMarkdown(target, workspace: workspace)

        let noise = try writeMarkdown(
            """
            ---
            topic: unrelated
            stage: research
            scope: research
            ---

            # Evidence
            Customer A onboarding blocker unrelated note.
            """,
            named: "research-wiki/wiki/unrelated.md",
            to: sourceRoot
        )
        _ = try await indexMarkdown(noise, workspace: workspace)

        let index = try ASKEvidenceIndex(workspaceURL: workspace)
        let hits = try await index.search(
            ASKEvidenceQuery(
                text: "onboarding blocker",
                filter: ASKEvidenceFilter(scopes: [.work], topics: ["customer-a-onboarding"], stages: ["prove"]),
                limit: 10
            )
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.metadata.scope == .work })
        XCTAssertTrue(hits.allSatisfy { $0.metadata.topic == "customer-a-onboarding" })
        XCTAssertTrue(hits.allSatisfy { $0.freshness == .ok })
    }

    func testListDocumentsUsesStoredMetadataWhenSourceIsMissing() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let url = try writeMarkdown(
            """
            ---
            topic: stored-topic
            scope: work
            type: report
            ---

            # Stored Metadata
            body
            """,
            named: "work-wiki/reports/stored-metadata.md",
            to: sourceRoot
        )
        let entry = try await indexMarkdown(url, workspace: workspace)
        try FileManager.default.removeItem(at: url)

        let index = try ASKEvidenceIndex(workspaceURL: workspace)
        let documents = try await index.listDocuments(filter: ASKEvidenceFilter(topics: ["stored-topic"]))
        let freshness = try await index.freshnessReport(filter: ASKEvidenceFilter(topics: ["stored-topic"]))

        XCTAssertEqual(documents.map(\.sourceID), [entry.sourceID])
        XCTAssertEqual(documents.first?.kind, .report)
        XCTAssertEqual(freshness.map(\.freshness), [.missing])
    }

    func testFreshnessDetectsStaleSource() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let url = try writeMarkdown(
            """
            ---
            topic: report-source
            scope: work
            ---

            # Report Source
            original
            """,
            named: "work-wiki/evidence/report-source.md",
            to: sourceRoot
        )
        let entry = try await indexMarkdown(url, workspace: workspace)
        let index = try ASKEvidenceIndex(workspaceURL: workspace)
        let initial = try await index.freshness(sourceID: entry.sourceID)
        XCTAssertEqual(initial?.freshness, .ok)

        try "# Report Source\nchanged\n".data(using: .utf8)?.write(to: url)
        let stale = try await index.freshness(sourceID: entry.sourceID)
        XCTAssertEqual(stale?.freshness, .stale)
    }


    func testBuildPackAppliesFreshnessFilterBeforeLimit() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let staleURL = try writeMarkdown(
            """
            ---
            topic: daily-closeout
            scope: work
            type: worklog
            ---

            # Stale Worklog
            needle needle needle needle needle needle needle needle needle needle
            """,
            named: "work-wiki/days/2026-04-20-stale.md",
            to: sourceRoot
        )
        _ = try await indexMarkdown(staleURL, workspace: workspace)
        try """
        # Stale Worklog
        changed needle needle needle needle needle needle needle needle needle needle
        """.data(using: .utf8)?.write(to: staleURL)

        let freshURL = try writeMarkdown(
            """
            ---
            topic: daily-closeout
            scope: work
            type: worklog
            ---

            # Fresh Worklog
            needle
            """,
            named: "work-wiki/days/2026-04-20-fresh.md",
            to: sourceRoot
        )
        let freshEntry = try await indexMarkdown(freshURL, workspace: workspace)

        let index = try ASKEvidenceIndex(workspaceURL: workspace)
        let pack = try await index.buildPack(
            ASKEvidencePackRequest(
                query: ASKEvidenceQuery(
                    text: "needle",
                    filter: ASKEvidenceFilter(scopes: [.work], kinds: [.worklog], topics: ["daily-closeout"]),
                    limit: 1
                ),
                includeStale: false
            )
        )

        XCTAssertEqual(pack.hits.map(\.sourceID), [freshEntry.sourceID])
        XCTAssertTrue(pack.hits.allSatisfy { $0.freshness == .ok })
    }

    func testPackRendererHonorsHardMaxBytes() async throws {
        let metadata = ASKEvidenceMetadata(sourceID: "src_test", sourcePath: "/tmp/source.md", documentTitle: "source", scope: .work, kind: .source)
        let hit = ASKEvidenceHit(
            sourceID: "src_test",
            nodeID: "n1",
            title: "Long Evidence",
            sectionPath: ["Long Evidence"],
            range: try SourceRange(space: .line, start: 1, end: 3),
            excerpt: String(repeating: "x", count: 10_000),
            score: 1,
            metadata: metadata,
            freshness: .ok
        )
        let pack = ASKEvidencePackRenderer.render(queryText: "long", hits: [hit], maxBytes: 256)
        XCTAssertLessThanOrEqual(pack.renderedMarkdown.data(using: .utf8)?.count ?? 0, 256)
        XCTAssertTrue(pack.truncated)
    }
    func testFreshnessSurfacesSourceReadFailure() async throws {
        let workspace = try tempDirectory()
        let sourceRoot = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let url = try writeMarkdown(
            "# Read Failure\noriginal\n",
            named: "work-wiki/evidence/read-failure.md",
            to: sourceRoot
        )
        let entry = try await indexMarkdown(url, workspace: workspace)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        do {
            _ = try await ASKEvidenceIndex(workspaceURL: workspace).freshness(sourceID: entry.sourceID)
            XCTFail("Expected source read failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testSearchRejectsNegativeLimits() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ask-evidence-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let index = try ASKEvidenceIndex(workspaceURL: workspace)

        do {
            _ = try await index.search(ASKEvidenceQuery(text: "query", limit: -1))
            XCTFail("negative query limits must fail")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("evidence query limit must be non-negative"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testBuildPackRejectsNegativeByteBudget() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ask-evidence-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let index = try ASKEvidenceIndex(workspaceURL: workspace)

        do {
            _ = try await index.buildPack(
                ASKEvidencePackRequest(query: ASKEvidenceQuery(text: "query"), maxBytes: -1)
            )
            XCTFail("negative evidence pack budgets must fail")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("evidence pack maxBytes must be non-negative"))
        }
    }

    func testSearchAndPackExcludeUnverifiedExtraction() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_unverified-evidence",
                type: .md,
                title: "Unverified Evidence",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "n1", title: "Needle", range: range)]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "blocked needle")],
            version: SourceVersion(checksum: "unverified", contentLength: 14, modifiedAt: nil),
            extractionQuality: .unsupported
        )
        let store = try SourceIndexStore(workspaceURL: workspace)
        _ = try await store.put(artifact)
        let index = try ASKEvidenceIndex(workspaceURL: workspace)

        let query = ASKEvidenceQuery(text: "needle", limit: 10)
        let hits = try await index.search(query)
        XCTAssertTrue(hits.isEmpty)
        let pack = try await index.buildPack(ASKEvidencePackRequest(query: query))
        XCTAssertTrue(pack.hits.isEmpty)
    }


}
