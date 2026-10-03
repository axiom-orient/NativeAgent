import XCTest
@testable import PageIndex

private struct FirstCandidateNavigator: VectorlessTreeNavigating {
    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        let candidate = try XCTUnwrap(prompt.candidates.first)
        let sourceIDs = prompt.stage == .corpus ? [candidate.sourceID.rawValue] : []
        let nodeIDs = prompt.stage == .document ? [candidate.id] : []
        return "{\"source_ids\":\(jsonArray(sourceIDs)),\"node_ids\":\(jsonArray(nodeIDs)),\"sufficient\":true}"
    }

    private func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

private struct MaximumCostNavigator: VectorlessTreeNavigating {
    var modelCallCost: Int { Int.max }

    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        let candidate = try XCTUnwrap(prompt.candidates.first)
        let sourceIDs = prompt.stage == .corpus ? [candidate.sourceID.rawValue] : []
        let nodeIDs = prompt.stage == .document ? [candidate.id] : []
        return "{\"source_ids\":\(jsonArray(sourceIDs)),\"node_ids\":\(jsonArray(nodeIDs)),\"sufficient\":true}"
    }

    private func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

private struct LastCandidateNavigator: VectorlessTreeNavigating {
    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        let candidate = try XCTUnwrap(prompt.candidates.last)
        let sourceIDs = prompt.stage == .corpus ? [candidate.sourceID.rawValue] : []
        let nodeIDs = prompt.stage == .document ? [candidate.id] : []
        return "{\"source_ids\":\(jsonArray(sourceIDs)),\"node_ids\":\(jsonArray(nodeIDs)),\"sufficient\":true}"
    }

    private func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

private struct InventedNodeNavigator: VectorlessTreeNavigating {
    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        "{\"source_ids\":[],\"node_ids\":[\"invented\"],\"sufficient\":true}"
    }
}

private struct MixedValidAndInventedNodeNavigator: VectorlessTreeNavigating {
    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        let nodeIDs: [String]
        if prompt.candidates.contains(where: { $0.id == "node_1" }) {
            nodeIDs = ["node_1"]
        } else {
            nodeIDs = ["node_2", "invented"]
        }
        return "{\"source_ids\":[],\"node_ids\":\(jsonArray(nodeIDs)),\"sufficient\":true}"
    }

    private func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

private struct InsufficientNavigator: VectorlessTreeNavigating {
    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        guard let candidate = prompt.candidates.first else {
            return "{\"source_ids\":[],\"node_ids\":[],\"sufficient\":false}"
        }
        let sourceIDs = prompt.stage == .corpus ? [candidate.sourceID.rawValue] : []
        let nodeIDs = prompt.stage == .document ? [candidate.id] : []
        return "{\"source_ids\":\(jsonArray(sourceIDs)),\"node_ids\":\(jsonArray(nodeIDs)),\"sufficient\":false}"
    }

    private func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

final class ASKPageIndexVectorlessRAGTests: XCTestCase, @unchecked Sendable {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSource(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.md")
        try "# Root\nroot material\n\n## Target\nexact cited evidence\n".data(using: .utf8)?.write(to: url)
        return url
    }

    private func artifact(sourceID: String, sourcePath: String) throws -> SourceIndexArtifact {
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let id = SourceID(sourceID)
        return SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: id,
                type: .md,
                title: sourceID,
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: sourceID, range: range, snippet: "evidence")]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "evidence")],
            version: SourceVersion(checksum: sourceID, contentLength: 8, modifiedAt: nil),
            sourcePath: sourcePath,
            extractionQuality: .digitalText
        )
    }

    func testExactTreeRetrievalReturnsVersionBoundAnchorsAndExcerpts() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try writeSource(to: workspace)
        let index = try ASKPageIndexExtension(workspaceURL: workspace)
        let entry = try await index.ingest(sourceAt: source)

        let result = try await index.retrieveEvidence(
            query: SourceEvidenceQuery(
                sourceSelection: .exact(sourceIDs: [entry.sourceID]),
                question: "target cited evidence",
                maxTreeDepth: 3,
                maxVisitedNodes: 4,
                maxRawEvidenceTokens: 50,
                maxModelCalls: 3
            ),
            navigator: FirstCandidateNavigator()
        )

        XCTAssertEqual(result.answerability, .sufficient)
        XCTAssertEqual(result.anchors.count, 1)
        XCTAssertEqual(result.anchors.first?.sourceID, entry.sourceID)
        XCTAssertEqual(result.anchors.first?.sourceVersionChecksum, entry.version.checksum)
        XCTAssertTrue(result.excerpts.contains { $0.content.contains("exact cited evidence") })
        XCTAssertLessThanOrEqual(result.trace.modelCalls, 3)
        XCTAssertLessThanOrEqual(result.trace.rawEvidenceTokens, 50)
    }

    func testInventedNavigatorNodeAndCapExhaustionReturnInsufficientInsteadOfGuessing() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try writeSource(to: workspace)
        let index = try ASKPageIndexExtension(workspaceURL: workspace)
        let entry = try await index.ingest(sourceAt: source)

        let invented = try await index.retrieveEvidence(
            query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [entry.sourceID]), question: "target", maxModelCalls: 2),
            navigator: InventedNodeNavigator()
        )
        XCTAssertEqual(invented.answerability, .insufficient)
        XCTAssertTrue(invented.excerpts.isEmpty)
        XCTAssertTrue(invented.trace.diagnostics.contains { $0.contains("unknown document node") })

        let capped = try await index.retrieveEvidence(
            query: SourceEvidenceQuery(
                sourceSelection: .exact(sourceIDs: [entry.sourceID]),
                question: "target",
                maxTreeDepth: 3,
                maxVisitedNodes: 1,
                maxRawEvidenceTokens: 50,
                maxModelCalls: 3
            ),
            navigator: FirstCandidateNavigator()
        )
        XCTAssertEqual(capped.answerability, .insufficient)
        XCTAssertTrue(capped.trace.diagnostics.contains { $0.contains("node visit cap") })
    }

    func testMixedValidAndUnknownNavigatorNodeFailsClosed() async throws {
        let range = try SourceRange(space: .line, start: 1, end: 2)
        let childRange = try SourceRange(space: .line, start: 2, end: 2)
        let sourceID = SourceID("src_mixed_navigator")
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .md,
                title: "root",
                coordinateSpace: .line,
                extentCount: 2,
                rootNodes: [
                    SourceIndexNode(
                        nodeID: "node_1",
                        title: "root",
                        range: range,
                        children: [SourceIndexNode(nodeID: "node_2", title: "child", range: childRange)]
                    )
                ]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "root"), SourceExcerpt(index: 2, content: "child")],
            version: SourceVersion(checksum: "mixed-v1", contentLength: 10, modifiedAt: nil),
            extractionQuality: .digitalText
        )

        let result = try await VectorlessTreeRAG(navigator: MixedValidAndInventedNodeNavigator()).retrieve(
            query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [sourceID]), question: "child"),
            artifacts: [artifact]
        )

        XCTAssertEqual(result.answerability, .insufficient)
        XCTAssertTrue(result.excerpts.isEmpty)
        XCTAssertTrue(result.trace.diagnostics.contains { $0.contains("unknown document node") })
    }

    func testUnavailableExactSourceDoesNotSilentlyNarrowTheEvidenceSet() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try writeSource(to: workspace)
        let index = try ASKPageIndexExtension(workspaceURL: workspace)
        let entry = try await index.ingest(sourceAt: source)

        let result = try await index.retrieveEvidence(
            query: SourceEvidenceQuery(
                sourceSelection: .exact(sourceIDs: [entry.sourceID, SourceID("src_unavailable")]),
                question: "target",
                maxModelCalls: 3
            ),
            navigator: FirstCandidateNavigator()
        )

        XCTAssertEqual(result.answerability, .insufficient)
        XCTAssertTrue(result.excerpts.isEmpty)
        XCTAssertTrue(result.trace.diagnostics.contains { $0.contains("exact sources are unavailable") })
    }

    func testMalformedArtifactCollectionsFailClosedInsteadOfTrapping() async throws {
        let duplicate = try artifact(sourceID: "src_duplicate", sourcePath: "/tmp/duplicate.md")

        do {
            _ = try await VectorlessTreeRAG(navigator: FirstCandidateNavigator()).retrieve(
                query: SourceEvidenceQuery(
                    sourceSelection: .exact(sourceIDs: [duplicate.document.sourceID]),
                    question: "evidence"
                ),
                artifacts: [duplicate, duplicate]
            )
            XCTFail("duplicate source artifacts must be rejected")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source evidence artifacts contain duplicate source IDs"))
        }

        let invalidRange = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_invalid_extent",
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
            _ = try await VectorlessTreeRAG(navigator: FirstCandidateNavigator()).retrieve(
                query: SourceEvidenceQuery(
                    sourceSelection: .exact(sourceIDs: ["src_invalid_extent"]),
                    question: "evidence"
                ),
                artifacts: [invalidRange]
            )
            XCTFail("out-of-bounds node ranges must be rejected")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source index node range is outside the document extent for src_invalid_extent"))
        }

        let duplicateNode = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_duplicate_node",
                type: .md,
                title: "duplicate node",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [
                    SourceIndexNode(
                        nodeID: "same",
                        title: "root",
                        range: try SourceRange(space: .line, start: 1, end: 1),
                        children: [
                            SourceIndexNode(
                                nodeID: "same",
                                title: "child",
                                range: try SourceRange(space: .line, start: 1, end: 1)
                            )
                        ]
                    )
                ]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "evidence")],
            version: SourceVersion(checksum: "duplicate-node", contentLength: 8, modifiedAt: nil),
            extractionQuality: .digitalText
        )

        do {
            _ = try await VectorlessTreeRAG(navigator: FirstCandidateNavigator()).retrieve(
                query: SourceEvidenceQuery(
                    sourceSelection: .exact(sourceIDs: ["src_duplicate_node"]),
                    question: "evidence"
                ),
                artifacts: [duplicateNode]
            )
            XCTFail("duplicate node IDs must be rejected")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source index contains duplicate or empty node ID in src_duplicate_node"))
        }

        let emptySourceID = try artifact(sourceID: "", sourcePath: "/tmp/empty-source-id.md")
        do {
            _ = try await VectorlessTreeRAG(navigator: FirstCandidateNavigator()).retrieve(
                query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [""]), question: "evidence"),
                artifacts: [emptySourceID]
            )
            XCTFail("empty source IDs must be rejected")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source index source ID must not be empty"))
        }

        let extremeExtent = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: "src_extreme_extent",
                type: .md,
                title: "extreme",
                coordinateSpace: .line,
                extentCount: Int.max,
                rootNodes: []
            ),
            excerpts: [],
            version: SourceVersion(checksum: "extreme", contentLength: 0, modifiedAt: nil),
            extractionQuality: .digitalText
        )
        do {
            _ = try await VectorlessTreeRAG(navigator: FirstCandidateNavigator()).retrieve(
                query: SourceEvidenceQuery(
                    sourceSelection: .exact(sourceIDs: ["src_extreme_extent"]),
                    question: "evidence"
                ),
                artifacts: [extremeExtent]
            )
            XCTFail("extreme extents must be rejected")
        } catch let error as ASKPageIndexError {
            XCTAssertEqual(error, .invalidArguments("source index extent must be finite and non-negative"))
        }
    }

    func testMaximumNavigatorCostDoesNotOverflowTraceAccounting() async throws {
        let source = try artifact(sourceID: "src_max_cost", sourcePath: "/tmp/max-cost.md")
        let result = try await VectorlessTreeRAG(navigator: MaximumCostNavigator()).retrieve(
            query: SourceEvidenceQuery(
                sourceSelection: .exact(sourceIDs: [source.document.sourceID]),
                question: "evidence",
                maxModelCalls: Int.max
            ),
            artifacts: [source]
        )

        XCTAssertEqual(result.answerability, .sufficient)
        XCTAssertEqual(result.trace.modelCalls, Int.max)
    }

    func testUnverifiedExtractionIsBlockedBeforeOpeningAnyEvidence() async throws {
        let range = try SourceRange(space: .line, start: 1, end: 1)
        let sourceID = SourceID("src_unverified")
        let artifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .md,
                title: "legacy",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: "root", range: range)]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "must not open")],
            version: SourceVersion(checksum: "v1", contentLength: 1, modifiedAt: nil),
            extractionQuality: .unsupported
        )

        let result = try await VectorlessTreeRAG(navigator: FirstCandidateNavigator()).retrieve(
            query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [sourceID]), question: "open", maxModelCalls: 1),
            artifacts: [artifact]
        )

        XCTAssertEqual(result.answerability, .extractionBlocked)
        XCTAssertEqual(result.trace.modelCalls, 0)
        XCTAssertTrue(result.excerpts.isEmpty)
    }

    func testScopedCorpusUsesPathComponentBoundaries() async throws {
        let inside = try artifact(sourceID: "src_inside", sourcePath: "/tmp/work/source.md")
        let sibling = try artifact(sourceID: "src_sibling", sourcePath: "/tmp/work-secret/source.md")

        let result = try await VectorlessTreeRAG(navigator: LastCandidateNavigator()).retrieve(
            query: SourceEvidenceQuery(
                sourceSelection: .scoped(corpusScope: SourceCorpusScope(pathPrefixes: ["/tmp/work"])),
                question: "evidence",
                maxModelCalls: 2
            ),
            artifacts: [inside, sibling]
        )

        XCTAssertEqual(result.answerability, .sufficient)
        XCTAssertEqual(result.anchors.map(\.sourceID), [inside.document.sourceID])
        XCTAssertFalse(result.anchors.contains { $0.sourceID == sibling.document.sourceID })

        let rootResult = try await VectorlessTreeRAG(navigator: LastCandidateNavigator()).retrieve(
            query: SourceEvidenceQuery(
                sourceSelection: .scoped(corpusScope: SourceCorpusScope(pathPrefixes: ["/"])),
                question: "evidence",
                maxModelCalls: 2
            ),
            artifacts: [inside, sibling]
        )
        XCTAssertEqual(rootResult.anchors.map(\.sourceID), [sibling.document.sourceID])

        let relative = try artifact(sourceID: "src_relative", sourcePath: "work/source.md")
        let relativeSibling = try artifact(sourceID: "src_relative_sibling", sourcePath: "work-secret/source.md")
        let relativeResult = try await VectorlessTreeRAG(navigator: LastCandidateNavigator()).retrieve(
            query: SourceEvidenceQuery(
                sourceSelection: .scoped(corpusScope: SourceCorpusScope(pathPrefixes: ["work/"])),
                question: "evidence",
                maxModelCalls: 2
            ),
            artifacts: [relative, relativeSibling]
        )
        XCTAssertEqual(relativeResult.anchors.map(\.sourceID), [relative.document.sourceID])
    }

    func testModelFreeNavigatorDoesNotConsumeModelBudgetAndExplicitInsufficiencyCannotClaimEvidence() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try writeSource(to: workspace)
        let index = try ASKPageIndexExtension(workspaceURL: workspace)
        let entry = try await index.ingest(sourceAt: source)

        let range = try SourceRange(space: .line, start: 1, end: 1)
        let flatSourceID = SourceID("src_flat_lexical")
        let flatArtifact = SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: flatSourceID,
                type: .md,
                title: "target",
                coordinateSpace: .line,
                extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "target", title: "target", range: range, snippet: "target evidence")]
            ),
            excerpts: [SourceExcerpt(index: 1, content: "target evidence")],
            version: SourceVersion(checksum: "flat_v1", contentLength: 15, modifiedAt: nil),
            extractionQuality: .digitalText
        )

        let modelFree = try await VectorlessTreeRAG().retrieve(
            query: SourceEvidenceQuery(
                sourceSelection: .exact(sourceIDs: [flatSourceID]),
                question: "target",
                maxModelCalls: 0
            ),
            artifacts: [flatArtifact]
        )
        XCTAssertEqual(modelFree.answerability, .sufficient)
        XCTAssertEqual(modelFree.trace.modelCalls, 0)

        let insufficient = try await index.retrieveEvidence(
            query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [entry.sourceID]), question: "target", maxModelCalls: 1),
            navigator: InsufficientNavigator()
        )
        XCTAssertEqual(insufficient.answerability, .insufficient)
        XCTAssertTrue(insufficient.excerpts.isEmpty)
        XCTAssertTrue(insufficient.trace.diagnostics.contains { $0.contains("document evidence insufficient") })
    }
}
