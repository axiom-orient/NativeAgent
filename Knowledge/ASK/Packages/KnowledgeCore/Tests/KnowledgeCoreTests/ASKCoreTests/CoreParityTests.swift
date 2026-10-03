
import Foundation
import Testing
@testable import KnowledgeCore

struct ASKCoreParityTests {
    @Test
    func stableHashAndIDMatchPythonFixture() throws {
        #expect(stableHash(["evidence_ingest", "src_demo", "sha256:demo", "2026-04-07T10:01:00Z"]) == "4ce2de63732158a1")
        #expect(stableID(prefix: "patch", parts: ["evidence_ingest", "src_demo", "sha256:demo", "2026-04-07T10:01:00Z"]) == "patch_4ce2de63732158a1")
        #expect(stableHashMap(["version": "0.3.0"]) == "4b86926956b9f42b")
    }

    @Test
    func projectionHashMatchesFixture() throws {
        let fixtureURL = SimulatorTestSupport.fixtureURL(name: "projection_request", withExtension: "json", filePath: #filePath)
        let request = try CanonicalJSON.decode(RefreshProjectionRequest.self, from: Data(contentsOf: fixtureURL))
        let write = try #require(request.proposedWrites.first)
        #expect(projectionDocumentHash(write.document) == "e06d6e414bcfbcd0")
    }

    @Test
    func collectedSourceFixtureShapeIsStable() throws {
        let url = SimulatorTestSupport.fixtureURL(name: "collected_source", withExtension: "json", filePath: #filePath)
        let object = try CanonicalJSON.object(from: Data(contentsOf: url)) as! [String: Any]
        #expect(object["source_id"] as? String == "src_demo")
        let fragments = object["fragments"] as? [[String: Any]]
        #expect(fragments?.count == 2)
    }

    @Test
    func canonicalJSONRoundTripsAcronymPropertyNames() throws {
        let value = AcronymFixture(sourceUUID: "uuid-1")
        let data = try CanonicalJSON.data(for: value)
        #expect(try CanonicalJSON.decode(AcronymFixture.self, from: data) == value)
    }
}

private struct AcronymFixture: Codable, Equatable {
    let sourceUUID: String
}
