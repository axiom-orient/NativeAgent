import Foundation
import Testing
@testable import ASK

struct ASKSourceVersionContractTests {
    @Test func exactEvidenceVersionSurvivesPublicCodableRoundTrip() throws {
        let item = ASKRAGEvidenceItem(sourceID: "source", sourceVersionChecksum: "exact-version",
            nodeID: "node", rangeStart: 1, rangeEnd: 2, excerptIndex: 1, content: "evidence")
        let bytes = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(ASKRAGEvidenceItem.self, from: bytes) == item)
        let request = ASKSourceInspectQuery(sourceID: item.sourceID, start: item.rangeStart,
            end: item.rangeEnd, sourceVersionChecksum: item.sourceVersionChecksum)
        #expect(try JSONDecoder().decode(ASKSourceInspectQuery.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func evidenceWithoutVersionIsRejectedWhileCurrentSourceInspectionRemainsExplicit() throws {
        let data = Data(#"{"sourceID":"source","nodeID":"node","rangeStart":1,"rangeEnd":1,"excerptIndex":1,"content":"old"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ASKRAGEvidenceItem.self, from: data)
        }
        let request = try JSONDecoder().decode(ASKSourceInspectQuery.self,
            from: Data(#"{"workspace":{},"sourceID":"source"}"#.utf8))
        #expect(request.sourceVersionChecksum == nil)
    }
}