import XCTest
@testable import PageIndex

private struct MockPDFDocumentSnapshotLoader: PDFDocumentSnapshotLoading {
    var snapshot: PDFDocumentSnapshot
    func loadSnapshot(from url: URL) throws -> PDFDocumentSnapshot { snapshot }
}

final class ASKPageIndexPDFTests: XCTestCase, @unchecked Sendable {
    private func fixturesURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    func testSnapshotPDFPageExtractorUsesInjectedLoader() throws {
        let pdfURL = fixturesURL().appendingPathComponent("pdf/earthmover.pdf")
        let snapshot = PDFDocumentSnapshot(title: "earthmover.pdf", pageTexts: ["p1", "p2"], outline: [])
        let extractor = SnapshotPDFPageExtractor(loader: MockPDFDocumentSnapshotLoader(snapshot: snapshot))
        let pageCount = try extractor.pageCount(for: pdfURL)
        let pages = try extractor.extractPages(from: pdfURL)
        XCTAssertEqual(pageCount, 2)
        XCTAssertEqual(pages.map { $0.content }, ["p1", "p2"])
    }

    func testFindTOCPagesExtendsPastInitialWindowOnlyDuringContinuousTOC() {
        let pages = PDFPhysicalIndexUtilities.findTOCPages(startPageIndex: 0, detectorResults: ["no", "yes", "yes", "no", "yes"], tocCheckPageNum: 2)
        XCTAssertEqual(pages, [1, 2])
    }

    func testExtractMatchingPagePairsKeepsMatchingPhysicalEntries() {
        let tocPage = [FlatTOCEntry(title: "A", page: 1), FlatTOCEntry(title: "B", page: 2), FlatTOCEntry(title: "C", page: 3)]
        let tocPhysical = [FlatTOCEntry(title: "A", physicalIndex: 6), FlatTOCEntry(title: "B", physicalIndex: 7), FlatTOCEntry(title: "C", physicalIndex: 8)]
        let pairs = PDFPhysicalIndexUtilities.extractMatchingPagePairs(tocPage: tocPage, tocPhysicalIndex: tocPhysical, startPageIndex: 5)
        XCTAssertEqual(pairs.count, 3)
    }

    func testCalculatePageOffsetUsesTheDominantDifference() {
        let pairs = [
            MatchingPagePair(title: "A", page: 1, physicalIndex: 6),
            MatchingPagePair(title: "B", page: 2, physicalIndex: 7),
            MatchingPagePair(title: "C", page: 3, physicalIndex: 8),
        ]
        XCTAssertEqual(PDFPhysicalIndexUtilities.calculatePageOffset(pairs), 5)
    }

    func testAddPageOffsetToTOCJSONMovesLogicalPagesToPhysicalIndices() {
        let shifted = PDFPhysicalIndexUtilities.addPageOffsetToTOCJSON([FlatTOCEntry(title: "A", page: 3)], offset: 5)
        XCTAssertEqual(shifted[0].physicalIndex, 8)
        XCTAssertNil(shifted[0].page)
    }

    func testPageListToGroupTextUsesOverlap() {
        let groups = PDFPhysicalIndexUtilities.pageListToGroupText(pageContents: ["A", "B", "C"], tokenLengths: [100, 100, 100], maxTokens: 150, overlapPage: 1)
        XCTAssertEqual(groups, ["A", "AB", "BC"])
    }

    func testPageListToGroupTextRejectsMismatchedTokenLengths() {
        XCTAssertTrue(
            PDFPhysicalIndexUtilities.pageListToGroupText(
                pageContents: ["A", "B"], tokenLengths: [1], maxTokens: 10
            ).isEmpty
        )
    }

    func testPageOffsetOverflowDoesNotPublishAnInvalidPhysicalIndex() {
        let shifted = PDFPhysicalIndexUtilities.addPageOffsetToTOCJSON(
            [FlatTOCEntry(title: "A", page: Int.max)], offset: 1
        )
        XCTAssertNil(shifted.first?.physicalIndex)
        XCTAssertNil(shifted.first?.page)
    }

    func testAddPrefaceIfNeededInsertsPreface() {
        let withPreface = PDFPhysicalIndexUtilities.addPrefaceIfNeeded([FlatTOCEntry(structure: "1", title: "Chapter 1", physicalIndex: 3)])
        XCTAssertEqual(withPreface.first?.title, "Preface")
        XCTAssertEqual(withPreface.first?.physicalIndex, 1)
    }

    func testValidateAndTruncatePhysicalIndicesRemovesOverflow() {
        let validated = PDFPhysicalIndexUtilities.validateAndTruncatePhysicalIndices([FlatTOCEntry(title: "A", physicalIndex: 5), FlatTOCEntry(title: "B", physicalIndex: 99)], pageListLength: 10, startIndex: 1)
        XCTAssertEqual(validated[0].physicalIndex, 5)
        XCTAssertNil(validated[1].physicalIndex)
    }

    func testPostProcessingBuildsTreeAndDerivesEndIndices() {
        let tree = PDFPhysicalIndexUtilities.postProcessing(structure: [FlatTOCEntry(structure: "1", title: "Intro", physicalIndex: 3), FlatTOCEntry(structure: "1.1", title: "Detail", physicalIndex: 5, appearStart: .yes), FlatTOCEntry(structure: "2", title: "Next", physicalIndex: 8, appearStart: .no)], endPhysicalIndex: 10)
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(tree[0].title, "Intro")
        XCTAssertEqual(tree[0].startIndex, 3)
        XCTAssertEqual(tree[0].endIndex, 4)
        XCTAssertEqual(tree[0].nodes?.first?.title, "Detail")
        XCTAssertEqual(tree[0].nodes?.first?.endIndex, 8)
        XCTAssertEqual(tree[1].title, "Next")
        XCTAssertEqual(tree[1].endIndex, 10)
    }

    func testSwiftPDFIndexerBuildsRangesFromOutline() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("sample.pdf")
        try Data("pdf".utf8).write(to: pdfURL)

        let snapshot = PDFDocumentSnapshot(
            title: "sample.pdf",
            pageTexts: ["p1", "p2", "p3", "p4"],
            outline: [
                PDFOutlineItem(title: "Intro", pageIndex: 1),
                PDFOutlineItem(title: "Body", pageIndex: 3, children: [
                    PDFOutlineItem(title: "Detail", pageIndex: 4),
                ]),
            ]
        )
        let indexer = SwiftPDFIndexer(loader: MockPDFDocumentSnapshotLoader(snapshot: snapshot))
        let options = ASKPageIndexOptions(model: nil, retrieveModel: nil, tocCheckPageNum: 20, maxPageNumEachNode: 10, maxTokenNumEachNode: 20_000, ifAddNodeID: .yes, ifAddNodeSummary: .yes, ifAddDocDescription: .yes, ifAddNodeText: .yes)

        let document = try await indexer.index(pdfAt: pdfURL, options: options)
        XCTAssertEqual(document.docName, "sample.pdf")
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertEqual(document.structure?.map { $0.title }, ["Intro", "Body"])
        XCTAssertEqual(document.structure?.first?.startIndex, 1)
        XCTAssertEqual(document.structure?.first?.endIndex, 2)
        XCTAssertEqual(document.structure?.last?.startIndex, 3)
        XCTAssertEqual(document.structure?.last?.endIndex, 4)
        XCTAssertEqual(document.structure?.last?.nodes?.first?.title, "Detail")
        XCTAssertEqual(document.structure?.last?.nodes?.first?.startIndex, 4)
        XCTAssertEqual(document.structure?.last?.nodes?.first?.endIndex, 4)
        XCTAssertEqual(document.structure?.first?.nodeID, "0000")
        XCTAssertNotNil(document.structure?.first?.summary)
        XCTAssertNotNil(document.docDescription)
        XCTAssertEqual(document.pages?.count, 4)
    }

    func testSwiftPDFIndexerFallsBackToSingleNodeWithoutOutline() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("plain.pdf")
        try Data("pdf".utf8).write(to: pdfURL)

        let snapshot = PDFDocumentSnapshot(title: "plain.pdf", pageTexts: ["a", "b", "c"], outline: [])
        let indexer = SwiftPDFIndexer(loader: MockPDFDocumentSnapshotLoader(snapshot: snapshot))
        let options = ASKPageIndexOptions(model: nil, retrieveModel: nil, tocCheckPageNum: 20, maxPageNumEachNode: 10, maxTokenNumEachNode: 20_000, ifAddNodeID: .yes, ifAddNodeSummary: .yes, ifAddDocDescription: .no, ifAddNodeText: .yes)

        let document = try await indexer.index(pdfAt: pdfURL, options: options)
        XCTAssertEqual(document.structure?.count, 1)
        XCTAssertEqual(document.structure?.first?.title, "plain.pdf")
        XCTAssertEqual(document.structure?.first?.startIndex, 1)
        XCTAssertEqual(document.structure?.first?.endIndex, 3)
    }

    func testSwiftPDFIndexerRejectsImageOnlyPDFUntilOCRIsSupplied() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("scan.pdf")
        try Data("pdf".utf8).write(to: pdfURL)
        let snapshot = PDFDocumentSnapshot(title: "scan.pdf", pageTexts: ["", "   "], outline: [])
        let indexer = SwiftPDFIndexer(loader: MockPDFDocumentSnapshotLoader(snapshot: snapshot))
        let options = ASKPageIndexOptions(model: nil, retrieveModel: nil, tocCheckPageNum: 20, maxPageNumEachNode: 10, maxTokenNumEachNode: 20_000, ifAddNodeID: .yes, ifAddNodeSummary: .yes, ifAddDocDescription: .no, ifAddNodeText: .yes)

        do {
            _ = try await indexer.index(pdfAt: pdfURL, options: options)
            XCTFail("image-only PDF must not create a searchable index")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .ocrRequired(pdfURL.path))
        }
    }

    func testSwiftPDFIndexerSplitsOversizedLeafNodesIntoPageChunks() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("chunked.pdf")
        try Data("pdf".utf8).write(to: pdfURL)

        let snapshot = PDFDocumentSnapshot(
            title: "chunked.pdf",
            pageTexts: ["one", "two", "three", "four", "five"],
            outline: [PDFOutlineItem(title: "Whole", pageIndex: 1)]
        )
        let indexer = SwiftPDFIndexer(loader: MockPDFDocumentSnapshotLoader(snapshot: snapshot))
        let options = ASKPageIndexOptions(model: nil, retrieveModel: nil, tocCheckPageNum: 20, maxPageNumEachNode: 2, maxTokenNumEachNode: 20_000, ifAddNodeID: .yes, ifAddNodeSummary: .yes, ifAddDocDescription: .no, ifAddNodeText: .yes)

        let document = try await indexer.index(pdfAt: pdfURL, options: options)
        let root = try XCTUnwrap(document.structure?.first)
        let maybeChildren: [DocumentNode]? = root.nodes
        let children = try XCTUnwrap(maybeChildren)
        XCTAssertEqual(children.map { $0.title }, ["Whole [pages 1-2]", "Whole [pages 3-4]", "Whole [page 5]"])
        XCTAssertEqual(children.map { $0.startIndex }, [1, 3, 5])
        XCTAssertEqual(children.map { $0.endIndex }, [2, 4, 5])
        XCTAssertNotNil(root.prefixSummary)
    }

    func testSwiftPDFIndexerCanDropNodeText() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("drop.pdf")
        try Data("pdf".utf8).write(to: pdfURL)

        let snapshot = PDFDocumentSnapshot(title: "drop.pdf", pageTexts: ["alpha beta"], outline: [PDFOutlineItem(title: "Single", pageIndex: 1)])
        let indexer = SwiftPDFIndexer(loader: MockPDFDocumentSnapshotLoader(snapshot: snapshot))
        let options = ASKPageIndexOptions(model: nil, retrieveModel: nil, tocCheckPageNum: 20, maxPageNumEachNode: 10, maxTokenNumEachNode: 20_000, ifAddNodeID: .yes, ifAddNodeSummary: .yes, ifAddDocDescription: .no, ifAddNodeText: .no)

        let document = try await indexer.index(pdfAt: pdfURL, options: options)
        XCTAssertNil(document.structure?.first?.text)
    }

    func testPDFKitLoaderIndexesActualFixtureOnApplePlatforms() async throws {
        #if canImport(PDFKit)
        let pdfURL = fixturesURL().appendingPathComponent("pdf/simple-text.pdf")
        let indexer = SwiftPDFIndexer(loader: PDFKitDocumentSnapshotLoader())
        let options = ASKPageIndexOptions(
            model: nil,
            retrieveModel: nil,
            tocCheckPageNum: 20,
            maxPageNumEachNode: 10,
            maxTokenNumEachNode: 20_000,
            ifAddNodeID: .yes,
            ifAddNodeSummary: .yes,
            ifAddDocDescription: .yes,
            ifAddNodeText: .yes
        )

        let document = try await indexer.index(pdfAt: pdfURL, options: options)

        XCTAssertEqual(document.type, .pdf)
        XCTAssertEqual(document.docName, "simple-text.pdf")
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.pages?.first?.page, 1)
        XCTAssertTrue(document.pages?.first?.content.contains("ASK WorkWiki PDF fixture") == true)
        XCTAssertEqual(document.structure?.first?.startIndex, 1)
        XCTAssertEqual(document.structure?.first?.endIndex, 1)
        #else
        throw XCTSkip("PDFKit fixture indexing runs on Apple platforms only")
        #endif
    }

    func testUnsupportedSnapshotLoaderReportsSwiftOnlyGateOnNonApplePlatforms() throws {
        #if canImport(PDFKit)
        throw XCTSkip("Non-Apple behavior only")
        #else
        let loader = UnsupportedPDFDocumentSnapshotLoader()
        let url = URL(fileURLWithPath: "/tmp/missing.pdf")
        XCTAssertThrowsError(try loader.loadSnapshot(from: url)) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .unsupportedOperation("PDF loading requires PDFKit on Apple platforms"))
        }
        #endif
    }
}
