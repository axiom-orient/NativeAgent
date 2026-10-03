import XCTest
@testable import PageIndex

private struct CountingTokenCounter: TokenCounting {
    func countTokens(in text: String, model: String?) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct FixedSummaryGenerator: MarkdownSummaryGenerating {
    func summary(for node: DocumentNode, model: String?) async throws -> String {
        "SUM:\(node.title)"
    }
}

private struct FixedDescriptionGenerator: MarkdownDescriptionGenerating {
    func description(for structure: [DocumentNode], model: String?) async throws -> String {
        "DESC:\(structure.count)"
    }
}

final class ASKPageIndexMarkdownTests: XCTestCase, @unchecked Sendable {
    private func fixturesURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    private func defaultOptions(
        ifAddNodeID: ToggleFlag = .yes,
        ifAddNodeSummary: ToggleFlag = .no,
        ifAddDocDescription: ToggleFlag = .no,
        ifAddNodeText: ToggleFlag = .yes,
        ifThinning: Bool = false,
        minTokenThreshold: Int? = nil,
        summaryTokenThreshold: Int = 200
    ) -> ASKPageIndexOptions {
        ASKPageIndexOptions(
            model: "mock-model",
            retrieveModel: nil,
            tocCheckPageNum: 20,
            maxPageNumEachNode: 10,
            maxTokenNumEachNode: 20_000,
            ifAddNodeID: ifAddNodeID,
            ifAddNodeSummary: ifAddNodeSummary,
            ifAddDocDescription: ifAddDocDescription,
            ifAddNodeText: ifAddNodeText,
            ifThinning: ifThinning,
            minTokenThreshold: minTokenThreshold,
            summaryTokenThreshold: summaryTokenThreshold
        )
    }

    func testExtractNodesFromMarkdownUsesCommonMarkRules() throws {
        let sampleURL = fixturesURL().appendingPathComponent("markdown/sample.md")
        let content = try String(contentsOf: sampleURL, encoding: .utf8)
        let (nodes, _) = MarkdownParser.extractNodesFromMarkdown(content)
        XCTAssertEqual(nodes.map(\.title), ["Root", "Child A", "Child B", "Indented Child Should Be Dropped Later", "Grandchild"])
        XCTAssertEqual(nodes.map(\.level), [1, 2, 2, 2, 3])
    }

    func testExtractNodeTextContentKeepsValidThreeSpaceIndentedHeading() throws {
        let sampleURL = fixturesURL().appendingPathComponent("markdown/sample.md")
        let content = try String(contentsOf: sampleURL, encoding: .utf8)
        let (nodes, lines) = MarkdownParser.extractNodesFromMarkdown(content)
        let flatNodes = MarkdownParser.extractNodeTextContent(nodes, markdownLines: lines)
        XCTAssertEqual(flatNodes.map(\.title), ["Root", "Child A", "Child B", "Indented Child Should Be Dropped Later", "Grandchild"])
    }

    func testIndexerPreservesSetextPreambleAndHeaderlessDocuments() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let preambleDocument = try await indexer.index(
            markdownContent: "intro\n\nSetext\n======\nbody\n",
            sourceName: "sample",
            options: defaultOptions(ifAddNodeID: .no, ifAddNodeSummary: .no, ifAddNodeText: .yes)
        )
        let preambleStructure = try XCTUnwrap(preambleDocument.structure)
        XCTAssertEqual(preambleStructure.map(\.title), ["(preamble)", "Setext"])
        XCTAssertEqual(preambleStructure.map(\.lineNumber), [1, 3])

        let headerlessDocument = try await indexer.index(
            markdownContent: "only body\nsecond line\n",
            sourceName: "headerless",
            options: defaultOptions(ifAddNodeID: .no, ifAddNodeSummary: .no, ifAddNodeText: .yes)
        )
        let headerlessStructure = try XCTUnwrap(headerlessDocument.structure)
        XCTAssertEqual(headerlessStructure.map(\.title), ["(document)"])
        XCTAssertEqual(headerlessStructure.first?.lineNumber, 1)
    }

    func testIndexerNormalizesCRLFBeforeUsingMarkdownParserLocations() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let document = try await indexer.index(
            markdownContent: "# Root\r\nbody\r\n\r\n## Child\r\ntext",
            sourceName: "crlf",
            options: defaultOptions(ifAddNodeID: .no, ifAddNodeSummary: .no, ifAddNodeText: .yes)
        )

        let structure = try XCTUnwrap(document.structure)
        XCTAssertEqual(document.lineCount, 5)
        XCTAssertEqual(structure.map(\.title), ["Root"])
        XCTAssertEqual(structure.first?.lineNumber, 1)
        XCTAssertEqual(structure.first?.nodes?.map(\.title), ["Child"])
        XCTAssertEqual(structure.first?.nodes?.first?.lineNumber, 4)
        XCTAssertEqual(structure.first?.text, "# Root\nbody")
    }

    func testNodeIDsRemainOneBasedWhenIDRewriteDisabled() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let document = try await indexer.index(markdownContent: "# Root\nbody\n\n## Child\nchild body\n", sourceName: "sample", options: defaultOptions(ifAddNodeID: .no, ifAddNodeSummary: .no, ifAddNodeText: .yes))
        let structure = try XCTUnwrap(document.structure)
        XCTAssertEqual(structure[0].nodeID, "0001")
        XCTAssertEqual(structure[0].nodes?.first?.nodeID, "0002")
    }

    func testNodeIDsRewriteToZeroBasedWhenEnabled() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let document = try await indexer.index(markdownContent: "# Root\nbody\n\n## Child\nchild body\n", sourceName: "sample", options: defaultOptions(ifAddNodeID: .yes, ifAddNodeSummary: .no, ifAddNodeText: .yes))
        let structure = try XCTUnwrap(document.structure)
        XCTAssertEqual(structure[0].nodeID, "0000")
        XCTAssertEqual(structure[0].nodes?.first?.nodeID, "0001")
    }

    func testSummariesPopulateLeavesAndInternalNodesAndCanRemoveText() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter(), summaryGenerator: FixedSummaryGenerator(), descriptionGenerator: FixedDescriptionGenerator())
        let document = try await indexer.index(markdownContent: "# Root\nroot body\n\n## Child\nchild body that exceeds threshold\n", sourceName: "sample", options: defaultOptions(ifAddNodeID: .yes, ifAddNodeSummary: .yes, ifAddDocDescription: .yes, ifAddNodeText: .no, summaryTokenThreshold: 1))
        XCTAssertEqual(document.docDescription, "DESC:1")
        let structure = try XCTUnwrap(document.structure)
        XCTAssertNil(structure[0].text)
        XCTAssertEqual(structure[0].prefixSummary, "SUM:Root")
        XCTAssertEqual(structure[0].nodes?.first?.summary, "SUM:Child")
        XCTAssertNil(structure[0].nodes?.first?.text)
    }

    func testDocumentDescriptionIsNotGeneratedWhenSummariesAreDisabled() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter(), summaryGenerator: FixedSummaryGenerator(), descriptionGenerator: FixedDescriptionGenerator())
        let document = try await indexer.index(markdownContent: "# Root\nbody\n", sourceName: "sample", options: defaultOptions(ifAddNodeID: .yes, ifAddNodeSummary: .no, ifAddDocDescription: .yes, ifAddNodeText: .yes, summaryTokenThreshold: 1))
        XCTAssertNil(document.docDescription)
    }

    func testThinningMergesChildrenBelowThreshold() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let document = try await indexer.index(markdownContent: "# Root\nroot body\n\n## Child\nchild body\n", sourceName: "sample", options: defaultOptions(ifAddNodeID: .yes, ifAddNodeSummary: .no, ifAddNodeText: .yes, ifThinning: true, minTokenThreshold: 100))
        let structure = try XCTUnwrap(document.structure)
        XCTAssertEqual(structure.count, 1)
        XCTAssertNil(structure[0].nodes)
        XCTAssertTrue((structure[0].text ?? "").contains("## Child"))
    }

    func testEmptyMarkdownUsesPythonCompatibleLineCount() async throws {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let document = try await indexer.index(markdownContent: "", sourceName: "empty", options: defaultOptions(ifAddNodeID: .yes, ifAddNodeSummary: .no, ifAddNodeText: .yes))
        XCTAssertEqual(document.lineCount, 1)
        XCTAssertEqual(document.structure ?? [], [])
    }

    func testThinningWithoutThresholdThrows() async {
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        await XCTAssertThrowsErrorAsync(try await indexer.index(markdownContent: "# Root\nbody\n", sourceName: "sample", options: defaultOptions(ifThinning: true, minTokenThreshold: nil))) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .invalidArguments("minTokenThreshold must be provided when thinning is enabled"))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: @autoclosure () -> String = "", _ errorHandler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
