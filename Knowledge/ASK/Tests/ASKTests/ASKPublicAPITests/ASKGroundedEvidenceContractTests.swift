import Foundation
import Testing
import EvidenceIndex
import PageIndex
@testable import ASK

@Test func groundedQueryDefaultsToCurrentSourceAndRoundTrips() throws {
    let input = ASKGroundedEvidenceQuery(text: "근거")
    #expect(input.freshnessRequirement == .currentSource)
    #expect(input.maxBytes == ASKEvidencePackRequest.defaultMaxBytes)
    let query = ASKQuery.groundedEvidence(input)
    let decoded = try JSONDecoder().decode(ASKQuery.self, from: JSONEncoder().encode(query))
    #expect(decoded == query)
}

@Test func exactResolverContractSurvivesRootQuerySerialization() throws {
    let reference = try ASKEvidenceReference(sourceID: "source", sourceVersionChecksum: "version",
        nodeID: "node", range: SourceRange(space: .line, start: 1, end: 2),
        contentSHA256: String(repeating: "a", count: 64))
    let query = ASKQuery.resolveEvidence(ASKResolveEvidenceQuery(reference: reference,
        freshnessRequirement: .retainedIndexedContent))
    #expect(try JSONDecoder().decode(ASKQuery.self, from: JSONEncoder().encode(query)) == query)
}

@Test func typedUnavailableIsNotAReplacementWithLatestContent() throws {
    let result = ASKQueryResult.resolvedEvidence(.unavailable(.versionMissing))
    #expect(try JSONDecoder().decode(ASKQueryResult.self, from: JSONEncoder().encode(result)) == result)
}
