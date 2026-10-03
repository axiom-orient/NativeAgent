import XCTest
@testable import PageIndex

final class ASKPageIndexCoreTests: XCTestCase, @unchecked Sendable {
    func testConfigLoaderLoadsBundledConfig() throws {
        let options = try ConfigLoader().load()
        XCTAssertEqual(options.model, "gpt-4o-2024-11-20")
        XCTAssertEqual(options.retrieveModel, "gpt-5.4")
        XCTAssertEqual(options.tocCheckPageNum, 20)
        XCTAssertEqual(options.maxPageNumEachNode, 10)
        XCTAssertEqual(options.maxTokenNumEachNode, 20_000)
        XCTAssertEqual(options.ifAddNodeID, .yes)
        XCTAssertEqual(options.ifAddNodeSummary, .yes)
        XCTAssertEqual(options.ifAddDocDescription, .no)
        XCTAssertEqual(options.ifAddNodeText, .no)
    }

    func testConfigLoaderRejectsUnknownKeys() {
        let yaml = """
        model: gpt-4o
        retrieve_model: gpt-5.4
        toc_check_page_num: 20
        max_page_num_each_node: 10
        max_token_num_each_node: 20000
        if_add_node_id: yes
        if_add_node_summary: yes
        if_add_doc_description: no
        if_add_node_text: no
        unexpected_key: boom
        """
        XCTAssertThrowsError(try ConfigLoader(yamlText: yaml)) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .unknownConfigKeys(["unexpected_key"]))
        }
    }


    func testPageRangeParserParsesAndDeduplicates() throws {
        XCTAssertEqual(try PageRangeParser.parse("5-7, 3, 7, 12"), [3, 5, 6, 7, 12])
    }

    func testPageRangeParserRejectsDescendingRange() {
        XCTAssertThrowsError(try PageRangeParser.parse("7-5")) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .invalidPagesFormat("7-5"))
        }
    }

    func testAssignNodeIDsStartsAtZero() {
        let tree = [DocumentNode(title: "Root", nodeID: "9999", nodes: [DocumentNode(title: "Child", nodeID: "8888")])]
        let rewritten = DocumentTreeUtilities.assignNodeIDs(tree, startingAt: 0)
        XCTAssertEqual(rewritten[0].nodeID, "0000")
        XCTAssertEqual(rewritten[0].nodes?.first?.nodeID, "0001")
    }

    func testRemoveTextRemovesRecursively() {
        let tree = [DocumentNode(title: "Root", text: "parent", nodes: [DocumentNode(title: "Child", text: "child")])]
        let removed = DocumentTreeUtilities.removeText(tree)
        XCTAssertNil(removed[0].text)
        XCTAssertNil(removed[0].nodes?.first?.text)
    }

    func testCreateCleanStructureForDescriptionKeepsAllowedFieldsOnly() {
        let tree = [DocumentNode(title: "Root", nodeID: "0000", startIndex: 1, endIndex: 2, summary: "sum", prefixSummary: "pref", text: "body", nodes: [DocumentNode(title: "Child", nodeID: "0001", summary: "child", text: "child-body")])]
        let cleaned = DocumentTreeUtilities.createCleanStructureForDescription(tree)
        XCTAssertEqual(cleaned[0].title, "Root")
        XCTAssertEqual(cleaned[0].nodeID, "0000")
        XCTAssertEqual(cleaned[0].summary, "sum")
        XCTAssertEqual(cleaned[0].prefixSummary, "pref")
        XCTAssertNil(cleaned[0].text)
        XCTAssertNil(cleaned[0].startIndex)
        XCTAssertNil(cleaned[0].endIndex)
        XCTAssertEqual(cleaned[0].nodes?.first?.summary, "child")
    }

    func testStableDigestMatchesKnownVectors() {
        XCTAssertEqual(StableDigest.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(StableDigest.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSourceRangeCountAndContains() throws {
        let range = try SourceRange(space: .page, start: 3, end: 5)
        XCTAssertEqual(range.count, 3)
        XCTAssertTrue(range.contains(3))
        XCTAssertTrue(range.contains(4))
        XCTAssertTrue(range.contains(5))
        XCTAssertFalse(range.contains(2))
        XCTAssertFalse(range.contains(6))
    }

    func testSourceRangeRejectsInvalidBounds() {
        XCTAssertThrowsError(try SourceRange(space: .page, start: 0, end: 1)) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .invalidSourceRange(start: 0, end: 1))
        }
        XCTAssertThrowsError(try SourceRange(space: .line, start: 5, end: 4)) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .invalidSourceRange(start: 5, end: 4))
        }
        XCTAssertThrowsError(try SourceRange(space: .line, start: Int.max, end: Int.max)) { error in
            XCTAssertEqual(error as? ASKPageIndexError, .invalidSourceRange(start: Int.max, end: Int.max))
        }
        let encoded = Data("{\"space\":\"line\",\"start\":1,\"end\":\(Int.max)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SourceRange.self, from: encoded))
    }

    func testSourceContractsRoundTripThroughJSON() throws {
        let range = try SourceRange(space: .page, start: 10, end: 12)
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_deadbeef",
                type: .pdf,
                title: "paper.pdf",
                description: "desc",
                coordinateSpace: .page,
                extentCount: 12,
                rootNodes: [
                    SourceIndexNode(nodeID: "n0", title: "Intro", range: range, summary: "sum", snippet: "snippet", children: []),
                ]
            ),
            excerpts: [SourceExcerpt(index: 10, content: "A")],
            version: SourceVersion(checksum: "deadbeef", contentLength: 10, modifiedAt: Date(timeIntervalSince1970: 0))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(artifact)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SourceIndexArtifact.self, from: data)
        XCTAssertEqual(decoded, artifact)
    }

}
