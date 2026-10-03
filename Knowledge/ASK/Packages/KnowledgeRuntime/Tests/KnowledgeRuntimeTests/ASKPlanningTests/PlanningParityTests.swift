
import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct ASKPlanningParityTests {
    @Test
    func collectedSourceToIngestRequestMatchesFixtureShape() throws {
        let collectedURL = SimulatorTestSupport.fixtureURL(name: "collected_source", withExtension: "json", filePath: #filePath)
        let expectedURL = SimulatorTestSupport.fixtureURL(name: "ingest_request", withExtension: "json", filePath: #filePath)

        let collected = try CanonicalJSON.decode(CollectedSource.self, from: Data(contentsOf: collectedURL))
        let request = try toIngestEvidenceRequest(
            collected,
            domain: "example/web",
            requestedAt: "2026-04-07T10:01:00Z"
        )
        let expected = try CanonicalJSON.decode(IngestEvidenceRequest.self, from: Data(contentsOf: expectedURL))

        #expect(request == expected)
    }

    @Test
    func evidenceIngestPatchMatchesPythonFixture() throws {
        let requestURL = SimulatorTestSupport.fixtureURL(name: "ingest_request", withExtension: "json", filePath: #filePath)
        let expectedURL = SimulatorTestSupport.fixtureURL(name: "ingest_patch", withExtension: "json", filePath: #filePath)

        let request = try CanonicalJSON.decode(IngestEvidenceRequest.self, from: Data(contentsOf: requestURL))
        let patch = try planEvidenceIngest(request)
        let expected = try CanonicalJSON.decode(KnowledgePatchPlan.self, from: Data(contentsOf: expectedURL))

        #expect(patch.patch == expected)
    }

    @Test
    func authorityRegistrationPatchMatchesPythonFixture() throws {
        let existingURL = SimulatorTestSupport.fixtureURL(name: "authority_existing", withExtension: "json", filePath: #filePath)
        let requestURL = SimulatorTestSupport.fixtureURL(name: "authority_request", withExtension: "json", filePath: #filePath)
        let expectedURL = SimulatorTestSupport.fixtureURL(name: "authority_patch", withExtension: "json", filePath: #filePath)

        let existing = try CanonicalJSON.decode(AuthorityRecord.self, from: Data(contentsOf: existingURL))
        let request = try CanonicalJSON.decode(RegisterAuthorityRequest.self, from: Data(contentsOf: requestURL))
        let patch = try planAuthorityRegistration(request, existingRecords: [existing])
        let expected = try CanonicalJSON.decode(KnowledgePatchPlan.self, from: Data(contentsOf: expectedURL))

        #expect(patch.patch == expected)
    }

    @Test
    func projectionRefreshPatchMatchesPythonFixture() throws {
        let requestURL = SimulatorTestSupport.fixtureURL(name: "projection_request", withExtension: "json", filePath: #filePath)
        let expectedURL = SimulatorTestSupport.fixtureURL(name: "projection_patch", withExtension: "json", filePath: #filePath)

        let request = try CanonicalJSON.decode(RefreshProjectionRequest.self, from: Data(contentsOf: requestURL))
        let patch = try planProjectionRefresh(request)
        let expected = try CanonicalJSON.decode(KnowledgePatchPlan.self, from: Data(contentsOf: expectedURL))

        #expect(patch.patch == expected)
    }
}
