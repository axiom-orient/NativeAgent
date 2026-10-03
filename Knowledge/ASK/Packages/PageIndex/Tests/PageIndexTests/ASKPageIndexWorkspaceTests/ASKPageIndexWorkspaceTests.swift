import XCTest
@testable import PageIndex

final class ASKPageIndexWorkspaceTests: XCTestCase, @unchecked Sendable {
    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMarkdownFixture(to directory: URL) throws -> URL {
        let markdownURL = directory.appendingPathComponent("sample.md")
        let markdown = """
        # Root
        root body

        ## Child
        child body
        """
        try markdown.data(using: .utf8)?.write(to: markdownURL)
        return markdownURL
    }

    func testReadOperationsDoNotCreateMissingWorkspaceState() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)

        let entries = try await store.list()
        let snapshot = try await store.snapshot()
        let revision = try await store.revisionToken()
        let artifact = try await store.get(sourceID: "missing")
        let history = try await store.history(sourceID: "missing")
        let backlink = try await store.getBacklink(knowledgeID: "missing")
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertNil(revision)
        XCTAssertNil(artifact)
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(backlink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".source-index.lock").path))
    }

    func testMarkdownSourceArtifactBuilderBuildsLineBasedArtifact() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()

        let artifact = try await builder.buildArtifact(from: markdownURL, options: options)
        XCTAssertEqual(artifact.document.type, .md)
        XCTAssertEqual(artifact.document.coordinateSpace, .line)
        XCTAssertEqual(artifact.document.extentCount, 5)
        XCTAssertEqual(artifact.document.rootNodes.first?.title, "Root")
        XCTAssertEqual(artifact.document.rootNodes.first?.range.start, 1)
        XCTAssertEqual(artifact.document.rootNodes.first?.range.end, 5)
        XCTAssertEqual(artifact.document.rootNodes.first?.children.first?.range.start, 4)
        XCTAssertEqual(artifact.document.rootNodes.first?.children.first?.range.end, 5)
        XCTAssertEqual(artifact.excerpts.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertTrue(artifact.document.sourceID.rawValue.hasPrefix("src_"))
    }

    func testMarkdownSourceArtifactBuilderForcesCanonicalIndexOptions() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let spy = WorkspaceMarkdownIndexerSpy(
            result: IndexedDocument(
                type: .md,
                path: markdownURL.path,
                docName: "sample",
                docDescription: "desc",
                lineCount: 5,
                structure: [
                    DocumentNode(title: "Root", nodeID: "node-1", lineNumber: 1, summary: "sum", text: "root body")
                ]
            )
        )
        let builder = MarkdownSourceArtifactBuilder(indexer: spy)
        let options = ASKPageIndexOptions(
            model: "custom-model",
            retrieveModel: nil,
            tocCheckPageNum: 3,
            maxPageNumEachNode: 4,
            maxTokenNumEachNode: 5,
            ifAddNodeID: .no,
            ifAddNodeSummary: .no,
            ifAddDocDescription: .no,
            ifAddNodeText: .no
        )

        let artifact = try await builder.buildArtifact(from: markdownURL, options: options)
        let captured = await spy.snapshot()
        XCTAssertEqual(captured?.url, markdownURL)
        XCTAssertEqual(captured?.options.ifThinning, false)
        XCTAssertNil(captured?.options.minTokenThreshold)
        XCTAssertEqual(captured?.options.summaryTokenThreshold, 200)
        XCTAssertEqual(captured?.options.ifAddNodeID, .yes)
        XCTAssertEqual(captured?.options.ifAddNodeSummary, .yes)
        XCTAssertEqual(captured?.options.ifAddDocDescription, .yes)
        XCTAssertEqual(captured?.options.ifAddNodeText, .yes)
        XCTAssertEqual(captured?.options.model, "custom-model")
        XCTAssertEqual(artifact.document.description, "desc")
        XCTAssertEqual(artifact.document.rootNodes.first?.nodeID, "node-1")
    }

    func testPDFSourceArtifactBuilderForcesCanonicalIndexOptions() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let pdfURL = workspace.appendingPathComponent("sample.pdf")
        try Data("pdf".utf8).write(to: pdfURL)
        let spy = WorkspacePDFIndexerSpy(
            result: IndexedDocument(
                type: .pdf,
                path: pdfURL.path,
                docName: "sample.pdf",
                docDescription: "desc",
                pageCount: 2,
                structure: [DocumentNode(title: "Intro", startIndex: 1, endIndex: 2, summary: "sum", text: "page 1")],
                pages: [DocumentPage(page: 1, content: "p1"), DocumentPage(page: 2, content: "p2")]
            )
        )
        let builder = PDFSourceArtifactBuilder(indexer: spy)
        let options = ASKPageIndexOptions(
            model: nil,
            retrieveModel: "retrieve-model",
            tocCheckPageNum: 7,
            maxPageNumEachNode: 8,
            maxTokenNumEachNode: 9,
            ifAddNodeID: .no,
            ifAddNodeSummary: .no,
            ifAddDocDescription: .no,
            ifAddNodeText: .no
        )

        let artifact = try await builder.buildArtifact(from: pdfURL, options: options)
        let captured = await spy.snapshot()
        XCTAssertEqual(captured?.url, pdfURL)
        XCTAssertEqual(captured?.options.retrieveModel, "retrieve-model")
        XCTAssertEqual(captured?.options.ifAddNodeID, .yes)
        XCTAssertEqual(captured?.options.ifAddNodeSummary, .yes)
        XCTAssertEqual(captured?.options.ifAddDocDescription, .yes)
        XCTAssertEqual(captured?.options.ifAddNodeText, .yes)
        XCTAssertEqual(artifact.document.description, "desc")
        XCTAssertEqual(artifact.document.rootNodes.first?.title, "Intro")
        XCTAssertEqual(artifact.excerpts.map(\.index), [1, 2])
        XCTAssertEqual(artifact.extractionQuality, .digitalText)
    }

    func testPDFSourceArtifactBuilderBuildsPageBasedArtifact() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let pdfURL = workspace.appendingPathComponent("paper.pdf")
        try Data("pdf".utf8).write(to: pdfURL)
        let snapshot = PDFDocumentSnapshot(
            title: "paper.pdf",
            pageTexts: ["p1", "p2", "p3"],
            outline: [
                PDFOutlineItem(title: "Intro", pageIndex: 1),
                PDFOutlineItem(title: "Body", pageIndex: 2),
            ]
        )
        let builder = PDFSourceArtifactBuilder(indexer: SwiftPDFIndexer(loader: WorkspacePDFSnapshotLoader(snapshot: snapshot)))
        let options = try ConfigLoader().load()

        let artifact = try await builder.buildArtifact(from: pdfURL, options: options)
        XCTAssertEqual(artifact.document.type, .pdf)
        XCTAssertEqual(artifact.document.coordinateSpace, .page)
        XCTAssertEqual(artifact.document.extentCount, 3)
        XCTAssertEqual(artifact.document.rootNodes.map(\.title), ["Intro", "Body"])
        XCTAssertEqual(artifact.document.rootNodes.first?.range.start, 1)
        XCTAssertEqual(artifact.document.rootNodes.first?.range.end, 1)
        XCTAssertEqual(artifact.document.rootNodes.last?.range.start, 2)
        XCTAssertEqual(artifact.document.rootNodes.last?.range.end, 3)
        XCTAssertEqual(artifact.excerpts.map(\.index), [1, 2, 3])
        XCTAssertEqual(artifact.extractionQuality, .digitalText)
    }

    func testPDFSourceArtifactBuilderRejectsEmptyInjectedExtraction() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let pdfURL = workspace.appendingPathComponent("scan.pdf")
        try Data("pdf".utf8).write(to: pdfURL)
        let spy = WorkspacePDFIndexerSpy(
            result: IndexedDocument(
                type: .pdf,
                path: pdfURL.path,
                docName: "scan.pdf",
                pageCount: 1,
                structure: [DocumentNode(title: "scan.pdf", startIndex: 1, endIndex: 1)],
                pages: [DocumentPage(page: 1, content: "")]
            )
        )
        let builder = PDFSourceArtifactBuilder(indexer: spy)

        do {
            _ = try await builder.buildArtifact(from: pdfURL, options: try ConfigLoader().load())
            XCTFail("empty PDF text must require OCR")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .ocrRequired(pdfURL.path))
        }
    }

    func testSourceIndexStorePersistsManifestAcrossReload() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let builder = MarkdownSourceArtifactBuilder()
        let options = try ConfigLoader().load()
        let artifact = try await builder.buildArtifact(from: markdownURL, options: options)

        let store = try SourceIndexStore(workspaceURL: workspace)
        let entry = try await store.put(artifact)
        XCTAssertEqual(entry.sourceID, artifact.document.sourceID)

        let reloadedStore = try SourceIndexStore(workspaceURL: workspace)
        let entries = try await reloadedStore.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sourceID, entry.sourceID)
        XCTAssertEqual(entries.first?.artifactFileName, entry.artifactFileName)
        XCTAssertEqual(entries.first?.type, entry.type)
        XCTAssertEqual(entries.first?.title, entry.title)
        XCTAssertEqual(entries.first?.version.checksum, entry.version.checksum)
        let loaded = try await reloadedStore.get(sourceID: artifact.document.sourceID)
        XCTAssertEqual(loaded?.document, artifact.document)
        XCTAssertEqual(loaded?.excerpts, artifact.excerpts)
        XCTAssertEqual(loaded?.version.checksum, artifact.version.checksum)
        XCTAssertEqual(loaded?.version.contentLength, artifact.version.contentLength)
    }

    func testSourceIndexStorePutGetAndListArtifact() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .page, start: 1, end: 2)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_store",
                type: .pdf,
                title: "paper.pdf",
                description: "desc",
                coordinateSpace: .page,
                extentCount: 2,
                rootNodes: [
                    SourceIndexNode(nodeID: "n0", title: "Intro", range: range, summary: "sum", snippet: "s", children: [])
                ]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "p1"), SourceExcerpt(index: 2, content: "p2")],
            version: SourceVersion(checksum: "abc", contentLength: 2, modifiedAt: Date(timeIntervalSince1970: 0))
        )

        let entry = try await store.put(artifact)
        XCTAssertEqual(entry.sourceID, "src_store")

        let entries = try await store.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sourceID, "src_store")

        let loaded = try await store.get(sourceID: "src_store")
        XCTAssertEqual(loaded, artifact)
    }

    func testSourceIndexStoreRejectsMalformedArtifactBeforeWriting() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_invalid_store",
                type: .md,
                title: "invalid",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [
                    SourceIndexNode(
                        nodeID: "root",
                        title: "root",
                        range: try SourceRange(space: .line, start: 1, end: 2)
                    )
                ]
            ),
            excerpts: [],
            version: SourceVersion(checksum: "invalid", contentLength: 0, modifiedAt: nil),
            extractionQuality: .digitalText
        )

        do {
            _ = try await store.put(artifact)
            XCTFail("malformed artifacts must be rejected before persistence")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source index node range is outside the document extent for src_invalid_store"))
        }
        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testSourceIndexStoreRejectsMalformedHistoricalArtifactOnRead() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let sourceID = SourceID("src_corrupt_history")
        let validRange = try SourceRange(space: .line, start: 1, end: 1)

        func makeArtifact(checksum: String, range: SourceRange) -> SourceIndexArtifact {
            SourceIndexArtifact(
                document: SourceIndexDocument(
                    sourceID: sourceID,
                    type: .md,
                    title: "history",
                    coordinateSpace: .line,
                    extentCount: 1,
                    rootNodes: [SourceIndexNode(nodeID: "root", title: "root", range: range)]
                ),
                excerpts: [SourceExcerpt(index: 1, content: "history")],
                version: SourceVersion(checksum: checksum, contentLength: 7, modifiedAt: nil),
                extractionQuality: .digitalText
            )
        }

        _ = try await store.put(makeArtifact(checksum: "v1", range: validRange))
        _ = try await store.put(makeArtifact(checksum: "v2", range: validRange))

        let historyDirectory = workspace
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(StableDigest.sha256Hex(Data(sourceID.rawValue.utf8)), isDirectory: true)
        let historyURL = historyDirectory.appendingPathComponent(
            "ver_\(StableDigest.sha256Hex(Data("v1".utf8))).json")
        let malformed = makeArtifact(
            checksum: "v1",
            range: try SourceRange(space: .line, start: 1, end: 2)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(malformed).write(to: historyURL, options: .atomic)

        do {
            _ = try await store.history(sourceID: sourceID)
            XCTFail("malformed historical artifacts must be rejected")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source index node range is outside the document extent for src_corrupt_history"))
        }
    }

    func testSourceIndexStoreHashesArtifactFileNameForPathUnsafeSourceID() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let unsafeSourceID = SourceID("../escape")
        let range = try SourceRange(space: .page, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: unsafeSourceID,
                type: .pdf,
                title: "paper.pdf",
                coordinateSpace: .page,
                extentCount: 1,
                rootNodes: [
                    SourceIndexNode(nodeID: "n0", title: "Intro", range: range)
                ]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "p1")],
            version: SourceVersion(checksum: "abc", contentLength: 1, modifiedAt: nil)
        )

        let entry = try await store.put(artifact)
        let expectedDigest = StableDigest.sha256Hex(Data(unsafeSourceID.rawValue.utf8))
        XCTAssertEqual(entry.artifactFileName, "src_\(expectedDigest).json")
        XCTAssertFalse(entry.artifactFileName.contains("/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape.json").path))

        let loaded = try await store.get(sourceID: unsafeSourceID)
        XCTAssertEqual(loaded, artifact)
    }

    func testSourceIndexStoreResolvesAnchorAgainstStoredArtifact() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .page, start: 1, end: 2)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_store",
                type: .pdf,
                title: "paper.pdf",
                description: "desc",
                coordinateSpace: .page,
                extentCount: 2,
                rootNodes: [
                    SourceIndexNode(nodeID: "n0", title: "Intro", range: range, summary: "sum", snippet: "s", children: [])
                ]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "p1"), SourceExcerpt(index: 2, content: "p2")],
            version: SourceVersion(checksum: "abc", contentLength: 2, modifiedAt: Date(timeIntervalSince1970: 0))
        )

        _ = try await store.put(artifact)
        let anchor = try XCTUnwrap(SourceIndexNavigator.makeAnchor(sourceID: "src_store", nodeID: "n0", in: artifact))
        let resolved = try await store.resolve(anchor: anchor)
        XCTAssertEqual(resolved?.documentTitle, "paper.pdf")
        XCTAssertEqual(resolved?.excerpts.map(\.index), [1, 2])
    }

    func testSourceIndexStoreDeleteRemovesArtifactAndManifestEntry() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .page, start: 1, end: 2)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_store",
                type: .pdf,
                title: "paper.pdf",
                description: "desc",
                coordinateSpace: .page,
                extentCount: 2,
                rootNodes: [
                    SourceIndexNode(nodeID: "n0", title: "Intro", range: range, summary: "sum", snippet: "s", children: [])
                ]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "p1"), SourceExcerpt(index: 2, content: "p2")],
            version: SourceVersion(checksum: "abc", contentLength: 2, modifiedAt: Date(timeIntervalSince1970: 0))
        )

        _ = try await store.put(artifact)
        try await store.delete(sourceID: "src_store")

        let remainingEntries = try await store.list()
        XCTAssertTrue(remainingEntries.isEmpty)
        let deleted = try await store.get(sourceID: "src_store")
        XCTAssertNil(deleted)
    }

    func testSourceIndexStorePersistsBacklinksAndResolvesBacklink() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_note",
                type: .md,
                title: "note",
                description: nil,
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "n0", title: "Root", range: range, children: [])]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "def", contentLength: 1, modifiedAt: Date(timeIntervalSince1970: 0))
        )
        _ = try await store.put(artifact)
        let anchor = try XCTUnwrap(SourceIndexNavigator.makeAnchor(sourceID: "src_note", nodeID: "n0", in: artifact))
        try await store.put(backlink: KnowledgeBacklink(knowledgeID: "k1", anchors: [anchor]))

        let reloadedStore = try SourceIndexStore(workspaceURL: workspace)
        let resolved = try await reloadedStore.resolveBacklink(knowledgeID: "k1")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.anchor.sectionPath, ["Root"])
        XCTAssertEqual(resolved.first?.excerpts.first?.content, "# Root")
    }

    func testSourceIndexStoreRejectsAnchorWhenRangeOrSectionPathDrifts() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 2)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_drift",
                type: .md,
                title: "note",
                description: nil,
                coordinateSpace: .line,
                extentCount: 2,
                rootNodes: [SourceIndexNode(nodeID: "n0", title: "Root", range: range, children: [])]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root"), SourceExcerpt(index: 2, content: "body")],
            version: SourceVersion(checksum: "ghi", contentLength: 2, modifiedAt: Date(timeIntervalSince1970: 0))
        )
        _ = try await store.put(artifact)
        let validAnchor = try XCTUnwrap(SourceIndexNavigator.makeAnchor(sourceID: "src_drift", nodeID: "n0", in: artifact))
        let resolvedValidAnchor = try await store.resolve(anchor: validAnchor)
        XCTAssertNotNil(resolvedValidAnchor)

        let wrongRangeAnchor = SourceAnchor(
            sourceID: validAnchor.sourceID,
            sourceVersionChecksum: validAnchor.sourceVersionChecksum,
            nodeID: validAnchor.nodeID,
            sectionPath: validAnchor.sectionPath,
            range: try SourceRange(space: .line, start: 1, end: 1),
            snippet: validAnchor.snippet
        )
        let resolvedWrongRange = try await store.resolve(anchor: wrongRangeAnchor)
        XCTAssertNil(resolvedWrongRange)

        let wrongPathAnchor = SourceAnchor(
            sourceID: validAnchor.sourceID,
            sourceVersionChecksum: validAnchor.sourceVersionChecksum,
            nodeID: validAnchor.nodeID,
            sectionPath: ["Other"],
            range: validAnchor.range,
            snippet: validAnchor.snippet
        )
        let resolvedWrongPath = try await store.resolve(anchor: wrongPathAnchor)
        XCTAssertNil(resolvedWrongPath)
    }

    func testSourceIndexStorePersistsBacklinkForSlashContainingKnowledgeID() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_slash",
                type: .md,
                title: "note",
                description: nil,
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "n0", title: "Root", range: range, children: [])]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "jkl", contentLength: 1, modifiedAt: Date(timeIntervalSince1970: 0))
        )
        _ = try await store.put(artifact)
        let anchor = try XCTUnwrap(SourceIndexNavigator.makeAnchor(sourceID: "src_slash", nodeID: "n0", in: artifact))
        try await store.put(backlink: KnowledgeBacklink(knowledgeID: "concepts/root", anchors: [anchor]))

        let files = try FileManager.default.contentsOfDirectory(at: workspace.appendingPathComponent("backlinks"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].lastPathComponent.contains("/"))

        let backlink = try await store.getBacklink(knowledgeID: "concepts/root")
        XCTAssertEqual(backlink?.knowledgeID, "concepts/root")
    }

    func testSourceIndexStoreAuditsDanglingBacklinksAfterSourceDeletion() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_audit",
                type: .md,
                title: "note",
                description: nil,
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "n0", title: "Root", range: range, children: [])]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "mno", contentLength: 1, modifiedAt: Date(timeIntervalSince1970: 0))
        )
        _ = try await store.put(artifact)
        let anchor = try XCTUnwrap(SourceIndexNavigator.makeAnchor(sourceID: "src_audit", nodeID: "n0", in: artifact))
        try await store.put(backlink: KnowledgeBacklink(knowledgeID: "k1", anchors: [anchor]))

        try await store.delete(sourceID: "src_audit")
        let report = try await store.auditBacklink(knowledgeID: "k1")
        XCTAssertTrue(report.resolved.isEmpty)
        XCTAssertEqual(report.unresolved, [anchor])
    }

    func testSourceIndexNavigatorCatalogFlattensNodesDepthFirst() throws {
        let lineRange = try SourceRange(space: .line, start: 1, end: 10)
        let childRange = try SourceRange(space: .line, start: 3, end: 5)
        let grandchildRange = try SourceRange(space: .line, start: 4, end: 4)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_catalog",
                type: .md,
                title: "note",
                description: nil,
                coordinateSpace: .line,
                extentCount: 10,
                rootNodes: [
                    SourceIndexNode(
                        nodeID: "n0",
                        title: "Root",
                        range: lineRange,
                        summary: "sum",
                        snippet: "snippet",
                        children: [
                            SourceIndexNode(
                                nodeID: "n1",
                                title: "Child",
                                range: childRange,
                                summary: nil,
                                snippet: "child",
                                children: [
                                    SourceIndexNode(nodeID: "n2", title: "Leaf", range: grandchildRange, children: [])
                                ]
                            )
                        ]
                    )
                ]
            ),
            excerpts: [],
            version: SourceVersion(checksum: "catalog", contentLength: 0, modifiedAt: nil)
        )

        let entries = SourceIndexNavigator.catalogEntries(sourceID: "src_catalog", in: artifact)
        XCTAssertEqual(entries.map(\.nodeID), ["n0", "n1", "n2"])
        XCTAssertEqual(entries.map(\.sectionPath), [["Root"], ["Root", "Child"], ["Root", "Child", "Leaf"]])
        XCTAssertEqual(entries.first?.summary, "sum")
        XCTAssertEqual(entries[1].snippet, "child")
    }

    func testDefaultSourceArtifactBuilderRejectsUnsupportedExtension() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let textURL = workspace.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: textURL)
        let builder = DefaultSourceArtifactBuilder()
        let options = try ConfigLoader().load()

        do {
            _ = try await builder.buildArtifact(from: textURL, options: options)
            XCTFail("Expected unsupported file format")
        } catch {
            XCTAssertEqual(error as? ASKPageIndexError, .unsupportedFileFormat(textURL.path))
        }
    }

    func testSourceIndexStoreRejectsNonCanonicalManifestArtifactFileName() throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let artifactsURL = workspace.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)

        let sourceID = SourceID("src_noncanonical")
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .md,
                title: "noncanonical.md",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "n0", title: "Root", range: range, children: [])]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "noncanonical", contentLength: 1, modifiedAt: nil)
        )
        let entry = SourceIndexManifestEntry(
            sourceID: sourceID,
            artifactFileName: "src_noncanonical.json",
            type: .md,
            title: "noncanonical.md",
            version: artifact.version
        )
        let encoder = JSONEncoderFactory.makeEncoder(prettyPrinted: true)
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact).write(to: artifactsURL.appendingPathComponent(entry.artifactFileName), options: .atomic)
        try encoder.encode([sourceID.rawValue: entry]).write(to: workspace.appendingPathComponent(SourceIndexStore.manifestFileName), options: .atomic)

        XCTAssertThrowsError(try SourceIndexStore(workspaceURL: workspace)) { error in
            XCTAssertEqual(
                error as? ASKPageIndexError,
                .invalidArguments("source index manifest contains non-canonical artifact path for src_noncanonical")
            )
        }
    }

    func testSourceIndexStoreOpenDoesNotCreateWorkspace() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ask-index-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let store = try SourceIndexStore(workspaceURL: workspace)

        let entries = try await store.list()
        let missingArtifact = try await store.get(sourceID: SourceID("src_missing"))

        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(missingArtifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testSourceIndexStoreSurfacesManifestArtifactLoss() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: SourceID("src_missing_artifact"),
                type: .md,
                title: "Missing Artifact",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "Root", range: range)]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "missing-artifact", contentLength: 6, modifiedAt: nil)
        )
        let entry = try await store.put(artifact)
        let artifactURL = workspace.appendingPathComponent("artifacts/\(entry.artifactFileName)")
        try FileManager.default.removeItem(at: artifactURL)

        do {
            _ = try await store.get(sourceID: artifact.document.sourceID)
            XCTFail("manifest-backed artifact loss must not be reported as absence")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .fileNotFound(artifactURL.path))
        }
    }


    func testSourceIndexStoreIgnoresOrphanArtifactWithoutManifestEntry() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: SourceID("src_orphan"),
                type: .md,
                title: "Orphan",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "Root", range: range)]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "orphan", contentLength: 6, modifiedAt: nil)
        )
        let entry = try await store.put(artifact)
        let encoder = JSONEncoderFactory.makeEncoder(prettyPrinted: true)
        try encoder.encode([String: SourceIndexManifestEntry]()).write(
            to: workspace.appendingPathComponent(SourceIndexStore.manifestFileName),
            options: .atomic
        )

        let reloaded = try SourceIndexStore(workspaceURL: workspace)
        let loaded = try await reloaded.get(sourceID: artifact.document.sourceID)

        XCTAssertNil(loaded)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("artifacts/\(entry.artifactFileName)").path
            )
        )
    }

    func testSourceIndexStoreRejectsArtifactThatDriftsFromManifest() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try SourceIndexStore(workspaceURL: workspace)
        let sourceID = SourceID("src_drift")
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .md,
                title: "Original",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "Root", range: range)]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "stable", contentLength: 6, modifiedAt: nil)
        )
        let entry = try await store.put(artifact)
        let driftedArtifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .md,
                title: "Drifted",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: artifact.document.rootNodes
            ),
            excerpts: artifact.excerpts,
            version: artifact.version
        )
        let encoder = JSONEncoderFactory.makeEncoder(prettyPrinted: true)
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(driftedArtifact).write(
            to: workspace.appendingPathComponent("artifacts/\(entry.artifactFileName)"),
            options: .atomic
        )

        let reloaded = try SourceIndexStore(workspaceURL: workspace)
        do {
            _ = try await reloaded.get(sourceID: sourceID)
            XCTFail("artifact drift must be surfaced")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(
                error,
                .invalidArguments("source index artifact does not match manifest for src_drift")
            )
        }
    }

    func testSourceIndexStoreRefreshesManifestAcrossStoreInstances() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let staleReader = try SourceIndexStore(workspaceURL: workspace)
        let writer = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: SourceID("src_cross_instance"),
                type: .md,
                title: "Cross instance",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "Root", range: range)]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "# Root")],
            version: SourceVersion(checksum: "cross-instance", contentLength: 6, modifiedAt: nil)
        )

        _ = try await writer.put(artifact)

        let loaded = try await staleReader.get(sourceID: artifact.document.sourceID)
        let entries = try await staleReader.list()
        XCTAssertEqual(loaded, artifact)
        XCTAssertEqual(entries.map(\.sourceID), [artifact.document.sourceID])
    }

    func testSourceIndexStoreMergesManifestAcrossStaleStoreInstances() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let firstStore = try SourceIndexStore(workspaceURL: workspace)
        let secondStore = try SourceIndexStore(workspaceURL: workspace)
        let range = try SourceRange(space: .line, start: 1, end: 1)

        func artifact(id: String, title: String) -> SourceIndexArtifact {
            SourceIndexArtifact(
                document: SourceIndexDocument(
                    sourceID: SourceID(id),
                    type: .md,
                    title: title,
                    coordinateSpace: .line,
                    extentCount: 1,
                    rootNodes: [
                        SourceIndexNode(nodeID: "root", title: title, range: range)
                    ]
                ),
                excerpts: [SourceExcerpt(index: 1, content: title)],
                version: SourceVersion(checksum: id, contentLength: title.count, modifiedAt: nil)
            )
        }

        _ = try await firstStore.put(artifact(id: "src_first", title: "First"))
        _ = try await secondStore.put(artifact(id: "src_second", title: "Second"))

        let reloadedStore = try SourceIndexStore(workspaceURL: workspace)
        let entries = try await reloadedStore.list()
        XCTAssertEqual(entries.map(\.sourceID), [SourceID("src_first"), SourceID("src_second")])
    }


}

private actor WorkspaceMarkdownIndexerSpy: MarkdownIndexing {
    struct Call: Sendable, Equatable {
        let url: URL
        let options: ASKPageIndexOptions
    }

    private(set) var lastCall: Call?
    private let result: IndexedDocument

    init(result: IndexedDocument) {
        self.result = result
    }

    func index(
        markdownAt url: URL,
        options: ASKPageIndexOptions
    ) async throws -> IndexedDocument {
        lastCall = Call(
            url: url,
            options: options
        )
        return result
    }

    func index(
        markdownContent: String,
        sourceName: String,
        sourcePath: String?,
        options: ASKPageIndexOptions
    ) async throws -> IndexedDocument {
        lastCall = Call(
            url: sourcePath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: sourceName),
            options: options
        )
        return result
    }

    func snapshot() -> Call? {
        lastCall
    }
}

private actor WorkspacePDFIndexerSpy: PDFIndexing {
    struct Call: Sendable, Equatable {
        let url: URL
        let options: ASKPageIndexOptions
    }

    private(set) var lastCall: Call?
    private let result: IndexedDocument

    init(result: IndexedDocument) {
        self.result = result
    }

    func index(pdfAt url: URL, options: ASKPageIndexOptions) async throws -> IndexedDocument {
        lastCall = Call(url: url, options: options)
        return result
    }

    func snapshot() -> Call? {
        lastCall
    }

}

private struct WorkspacePDFSnapshotLoader: PDFDocumentSnapshotLoading {
    let snapshot: PDFDocumentSnapshot
    func loadSnapshot(from url: URL) throws -> PDFDocumentSnapshot { snapshot }
}
