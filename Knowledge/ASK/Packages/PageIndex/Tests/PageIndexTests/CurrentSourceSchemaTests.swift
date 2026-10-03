import Foundation
import Testing
@testable import PageIndex

struct CurrentSourceSchemaTests {
    private func artifact(schema: Int = SourceIndexArtifact.currentSchemaVersion) throws -> SourceIndexArtifact {
        SourceIndexArtifact(schemaVersion: schema,
            document: SourceIndexDocument(sourceID: "source", type: .md, title: "Current",
                coordinateSpace: .line, extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "node", title: "Current",
                    range: try SourceRange(space: .line, start: 1, end: 1), snippet: "Content")]),
            excerpts: [SourceExcerpt(index: 1, content: "Content")],
            version: SourceVersion(checksum: "revision", contentLength: 7, modifiedAt: nil),
            extractionQuality: .digitalText)
    }

    @Test(arguments: ["schemaVersion", "extractionQuality"])
    func missingCurrentFieldsRejectDecoding(field: String) throws {
        let data = try JSONEncoder().encode(artifact())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: field)
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceIndexArtifact.self, from: incomplete)
        }
    }

    @Test(arguments: [2, 4])
    func unsupportedSchemaRejectsDecodeAndWriteWithoutCreatingManifest(schema: Int) async throws {
        let value = try artifact(schema: schema)
        let data = try JSONEncoder().encode(value)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SourceIndexArtifact.self, from: data) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceIndexStore(workspaceURL: root)
        await #expect(throws: ASKPageIndexError.self) { try await store.put(value) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(SourceIndexStore.manifestFileName).path))
        #expect(try await store.list().isEmpty)
    }

    @Test func sourceAnchorRequiresExactVersionOnDecode() throws {
        let anchor = SourceAnchor(sourceID: "source", sourceVersionChecksum: "revision",
            nodeID: "node", sectionPath: [], range: try SourceRange(space: .line, start: 1, end: 1), snippet: "Content")
        let data = try JSONEncoder().encode(anchor)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sourceVersionChecksum")
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SourceAnchor.self, from: incomplete) }
    }
}
