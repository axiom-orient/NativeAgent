import Testing

@testable import NativeAgentDomain

private enum OperationCleanupFixtureError: Error, CustomStringConvertible, Equatable {
    case operation
    case cleanup

    var description: String {
        switch self {
        case .operation: "operation"
        case .cleanup: "cleanup"
        }
    }
}

@Test
func operationCleanupPolicyReturnsSuccessfulValue() throws {
    let value = try OperationCleanupCompletionPolicy.resolve(
        operation: .success("value"),
        cleanupError: nil
    )
    #expect(value == "value")
}

@Test
func operationCleanupPolicyPreservesOperationFailure() {
    #expect(throws: OperationCleanupFixtureError.operation) {
        let _: String = try OperationCleanupCompletionPolicy.resolve(
            operation: .failure(OperationCleanupFixtureError.operation),
            cleanupError: nil
        )
    }
}

@Test
func operationCleanupPolicyPreservesCleanupFailureAfterSuccess() {
    #expect(throws: OperationCleanupFixtureError.cleanup) {
        let _: String = try OperationCleanupCompletionPolicy.resolve(
            operation: .success("value"),
            cleanupError: OperationCleanupFixtureError.cleanup
        )
    }
}

@Test
func operationCleanupPolicyPreservesBothFailures() {
    #expect(
        throws: OperationAndCleanupFailure(
            operationFailure: "operation",
            cleanupFailure: "cleanup"
        )
    ) {
        let _: String = try OperationCleanupCompletionPolicy.resolve(
            operation: .failure(OperationCleanupFixtureError.operation),
            cleanupError: OperationCleanupFixtureError.cleanup
        )
    }
}
