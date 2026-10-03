import XCTest
@testable import PageIndex

final class ASKPageIndexASKTests: XCTestCase, @unchecked Sendable {
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

    func testASKPageIndexExtensionIngestsMarkdownAndResolvesBacklink() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let indexExtension = try ASKPageIndexExtension(workspaceURL: workspace)

        let entry = try await indexExtension.ingest(sourceAt: markdownURL)
        let entries = try await indexExtension.listSources()
        XCTAssertEqual(entries.map(\.sourceID), [entry.sourceID])

        let maybeArtifact = try await indexExtension.artifact(sourceID: entry.sourceID)
        let artifact = try XCTUnwrap(maybeArtifact)
        let rootNodeID = try XCTUnwrap(artifact.document.rootNodes.first?.nodeID)
        let maybeAnchor = try await indexExtension.makeAnchor(sourceID: entry.sourceID, nodeID: rootNodeID)
        let anchor = try XCTUnwrap(maybeAnchor)
        XCTAssertEqual(anchor.sectionPath, ["Root"])

        let backlink = try await indexExtension.attach(knowledgeID: "k1", anchors: [anchor, anchor])
        XCTAssertEqual(backlink.anchors.count, 1)
        let resolved = try await indexExtension.resolveBacklink(knowledgeID: "k1")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.documentTitle, "sample")
        XCTAssertTrue((resolved.first?.excerpts.first?.content ?? "").contains("# Root"))
    }

    func testASKPageIndexExtensionRejectsUnresolvedAnchor() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let indexExtension = try ASKPageIndexExtension(workspaceURL: workspace)
        let anchor = SourceAnchor(
            sourceID: "src_missing",
            sourceVersionChecksum: "missing",
            nodeID: "n0",
            sectionPath: ["Missing"],
            range: try SourceRange(space: .page, start: 1, end: 1),
            snippet: "missing"
        )

        do {
            _ = try await indexExtension.attach(knowledgeID: "k1", anchors: [anchor])
            XCTFail("Expected attach to reject unresolved anchor")
        } catch {
            XCTAssertEqual(error as? ASKPageIndexError, .unresolvedSourceAnchor(sourceID: "src_missing", nodeID: "n0"))
        }
    }

    func testASKPageIndexExtensionCatalogAndAuditBacklink() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let indexExtension = try ASKPageIndexExtension(workspaceURL: workspace)
        let entry = try await indexExtension.ingest(sourceAt: markdownURL)
        let catalog = try await indexExtension.catalog(sourceID: entry.sourceID)
        XCTAssertEqual(catalog.map(\.sectionPath), [["Root"], ["Root", "Child"]])

        let anchor = try XCTUnwrap(catalog.first).nodeID
        let maybeSourceAnchor = try await indexExtension.makeAnchor(sourceID: entry.sourceID, nodeID: anchor)
        let sourceAnchor = try XCTUnwrap(maybeSourceAnchor)
        _ = try await indexExtension.attach(knowledgeID: "concepts/root", anchors: [sourceAnchor])
        let report = try await indexExtension.auditBacklink(knowledgeID: "concepts/root")
        XCTAssertEqual(report.resolved.count, 1)
        XCTAssertTrue(report.unresolved.isEmpty)
    }

    func testASKPageIndexExtensionPersistsAcrossReload() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let extension1 = try ASKPageIndexExtension(workspaceURL: workspace)
        let entry = try await extension1.ingest(sourceAt: markdownURL)

        let extension2 = try ASKPageIndexExtension(workspaceURL: workspace)
        let entries = try await extension2.listSources()
        XCTAssertEqual(entries.map(\.sourceID), [entry.sourceID])
        let artifact = try await extension2.artifact(sourceID: entry.sourceID)
        XCTAssertEqual(artifact?.document.title, "sample")
    }


    func testASKPageIndexExtensionExposesBuildAndUpdateAliases() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let indexExtension = try ASKPageIndexExtension(workspaceURL: workspace)

        let built = try await indexExtension.build(sourceAt: markdownURL)
        let updated = try await indexExtension.update(sourceAt: markdownURL)

        XCTAssertEqual(built.sourceID, updated.sourceID)
        let entries = try await indexExtension.listSources()
        XCTAssertEqual(entries.map(\.sourceID), [built.sourceID])
    }

    func testReingestKeepsLogicalSourceIDAndInvalidatesOldVersionAnchors() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let indexExtension = try ASKPageIndexExtension(workspaceURL: workspace)

        let first = try await indexExtension.ingest(sourceAt: markdownURL)
        let maybeFirstArtifact = try await indexExtension.artifact(sourceID: first.sourceID)
        let firstArtifact = try XCTUnwrap(maybeFirstArtifact)
        let rootNodeID = try XCTUnwrap(firstArtifact.document.rootNodes.first?.nodeID)
        let maybeOldAnchor = try await indexExtension.makeAnchor(sourceID: first.sourceID, nodeID: rootNodeID)
        let oldAnchor = try XCTUnwrap(maybeOldAnchor)
        _ = try await indexExtension.attach(knowledgeID: "concepts/historical-root", anchors: [oldAnchor])
        try "# Root\nchanged body\n".data(using: .utf8)?.write(to: markdownURL)

        let second = try await indexExtension.update(sourceAt: markdownURL)
        let maybeSecondArtifact = try await indexExtension.artifact(sourceID: second.sourceID)
        let secondArtifact = try XCTUnwrap(maybeSecondArtifact)
        let entries = try await indexExtension.listSources()
        let resolvedOldAnchor = try await indexExtension.resolve(anchor: oldAnchor)
        let store = try SourceIndexStore(workspaceURL: workspace)
        let history = try await store.history(sourceID: first.sourceID)
        XCTAssertEqual(first.sourceID, second.sourceID)
        XCTAssertNotEqual(first.version.checksum, second.version.checksum)
        XCTAssertEqual(secondArtifact.version.checksum, second.version.checksum)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(history.map(\.version.checksum), [first.version.checksum])
        XCTAssertEqual(resolvedOldAnchor?.anchor.sourceVersionChecksum, first.version.checksum)
        let historicalBacklink = try await indexExtension.auditBacklink(knowledgeID: "concepts/historical-root")
        XCTAssertEqual(historicalBacklink.resolved.map(\.anchor), [oldAnchor])
        XCTAssertTrue(historicalBacklink.unresolved.isEmpty)
    }
}


extension ASKPageIndexASKTests {
    func testIOSServiceCanCatalogAndAuditBacklinks() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let macService = try ASKPageIndexMacService(workspaceURL: workspace)
        let entry = try await macService.ingest(sourceAt: markdownURL)
        let artifact = try await macService.artifact(sourceID: entry.sourceID)
        let nodeID = try XCTUnwrap(artifact?.document.rootNodes.first?.nodeID)
        let maybeAnchor = try await macService.makeAnchor(sourceID: entry.sourceID, nodeID: nodeID)
        let anchor = try XCTUnwrap(maybeAnchor)
        _ = try await macService.attach(knowledgeID: "concepts/root", anchors: [anchor])

        let iosService = try ASKPageIndexIOSService(workspaceURL: workspace)
        let catalog = try await iosService.catalog(sourceID: entry.sourceID)
        XCTAssertEqual(catalog.map(\.nodeID), [nodeID, try XCTUnwrap(artifact?.document.rootNodes.first?.children.first?.nodeID)])
        let report = try await iosService.auditBacklink(knowledgeID: "concepts/root")
        XCTAssertEqual(report.resolved.count, 1)
        XCTAssertTrue(report.unresolved.isEmpty)
    }

    func testIOSServiceConsumesArtifactsProducedByMacService() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let macService = try ASKPageIndexMacService(workspaceURL: workspace)
        let entry = try await macService.ingest(sourceAt: markdownURL)

        let iosService = try ASKPageIndexIOSService(workspaceURL: workspace)
        let entries = try await iosService.listSources()
        XCTAssertEqual(entries.map(\.sourceID), [entry.sourceID])
        let artifact = try await iosService.artifact(sourceID: entry.sourceID)
        XCTAssertEqual(artifact?.document.coordinateSpace, .line)
        let nodeID = try XCTUnwrap(artifact?.document.rootNodes.first?.nodeID)
        let anchor = try await iosService.makeAnchor(sourceID: entry.sourceID, nodeID: nodeID)
        XCTAssertEqual(anchor?.sectionPath, ["Root"])
    }


    func testMacServiceExposesBuildAndUpdateAliases() async throws {
        let workspace = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let markdownURL = try writeMarkdownFixture(to: workspace)
        let macService = try ASKPageIndexMacService(workspaceURL: workspace)

        let built = try await macService.build(sourceAt: markdownURL)
        let updated = try await macService.update(sourceAt: markdownURL)

        XCTAssertEqual(built.sourceID, updated.sourceID)
        let entries = try await macService.listSources()
        XCTAssertEqual(entries.map(\.sourceID), [built.sourceID])
    }
}
