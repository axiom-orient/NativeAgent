import Foundation
import Testing
@testable import ASKTutor

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
func nonfiniteTutorConfigurationIsRejectedWithoutDefaulting(threshold: Double) {
    let config = TutorConfiguration(highScoreThreshold: threshold)
    #expect(throws: ASKTutorError.self) { try config.validate() }
}

@Test
func mutatedTutorConfigurationIsRejected() {
    var config = TutorConfiguration()
    config.reviewIntervalsDays = []
    #expect(throws: ASKTutorError.self) { try config.validate() }
    config = TutorConfiguration()
    config.partialScoreThreshold = 0.99
    #expect(throws: ASKTutorError.self) { try config.validate() }
}

@Test
func decodedTutorConfigurationUsesTheSameValidation() throws {
    var config = TutorConfiguration()
    config.searchLimit = -1
    let bytes = try JSONEncoder().encode(config)
    #expect(throws: ASKTutorError.self) {
        _ = try JSONDecoder().decode(TutorConfiguration.self, from: bytes)
    }
    let valid = TutorConfiguration()
    #expect(try JSONDecoder().decode(TutorConfiguration.self, from: JSONEncoder().encode(valid)) == valid)
}
