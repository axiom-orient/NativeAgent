import Foundation
import XCTest
@testable import PageIndex

final class MarkdownSourceLineEndingTests: XCTestCase, @unchecked Sendable {
    func testLogicalRangesMatchOutlineWithoutChangingRawVersionBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pageindex-line-endings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expectedLines = ["# Root", "alpha", "", "## Child", "beta", ""]
        let variants = [
            expectedLines.joined(separator: "\n"),
            expectedLines.joined(separator: "\r\n"),
            expectedLines.joined(separator: "\r"),
            "# Root\r\nalpha\r\n\r## Child\nbeta\r\n",
        ]
        for (index, markdown) in variants.enumerated() {
            let source = root.appendingPathComponent("source-\(index).md")
            let raw = Data(markdown.utf8)
            try raw.write(to: source)
            let artifact = try await MarkdownSourceArtifactBuilder().buildArtifact(from: source, options: ConfigLoader().load())
            XCTAssertEqual(artifact.document.extentCount, expectedLines.count)
            XCTAssertEqual(artifact.excerpts.map(\.content), expectedLines)
            XCTAssertEqual(artifact.excerpts.map(\.index), Array(1...expectedLines.count))
            XCTAssertEqual(artifact.document.rootNodes.first?.range.start, 1)
            XCTAssertEqual(artifact.document.rootNodes.first?.children.first?.range.start, 4)
            XCTAssertEqual(artifact.document.rootNodes.first?.children.first?.range.end, 6)
            XCTAssertEqual(artifact.version.checksum, StableDigest.sha256Hex(raw))
            XCTAssertEqual(artifact.version.contentLength, raw.count)
            let lfBytes = Data(expectedLines.joined(separator: "\n").utf8)
            if raw != lfBytes {
                XCTAssertNotEqual(artifact.version.checksum, StableDigest.sha256Hex(lfBytes))
            }
            XCTAssertEqual(try Data(contentsOf: source), raw)
            let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index-\(index)"))
            _ = try await store.put(artifact)
            let reopened = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index-\(index)"))
            let persisted = try await reopened.get(sourceID: artifact.document.sourceID, versionChecksum: artifact.version.checksum)
            XCTAssertEqual(persisted?.excerpts, artifact.excerpts)
        }
    }
}
