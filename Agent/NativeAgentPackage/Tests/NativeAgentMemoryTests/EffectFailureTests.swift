import XCTest
@testable import NativeAgentDomain

final class EffectFailureTests: XCTestCase {
    private struct PlainFailure: Error {}

    func testUnclassifiedFailureIsOutcomeUnknown() {
        XCTAssertEqual(
            EffectFailureClassifier.certainty(for: PlainFailure()),
            .outcomeUnknown
        )
    }

    func testExplicitDefiniteFailureIsPreserved() {
        let failure = EffectFailure.definiteFailure(
            operation: "test.operation",
            cause: "input rejected",
            context: ["requestID": "request-1"]
        )

        XCTAssertEqual(
            EffectFailureClassifier.certainty(for: failure),
            .definiteFailure
        )
        XCTAssertTrue(failure.localizedDescription.contains("test.operation"))
        XCTAssertTrue(failure.localizedDescription.contains("requestID=request-1"))
    }

    func testExplicitUnknownOutcomeIsPreserved() {
        let failure = EffectFailure.outcomeUnknown(
            operation: "test.mutation",
            cause: "connection closed after send"
        )

        XCTAssertEqual(
            EffectFailureClassifier.certainty(for: failure),
            .outcomeUnknown
        )
    }
}
