import Testing

@testable import NativeAgentSkills

private enum AccessOperationFixtureError: Error, Equatable {
    case operation
    case release
}

@Test
func skillLibraryAccessCompletionPolicyReturnsSuccessfulValue() throws {
    let value: String = try SkillLibraryAccessCompletionPolicy().resolve(
        outcome: .success("completed"),
        releaseError: nil
    )

    #expect(value == "completed")
}

@Test
func skillLibraryAccessCompletionPolicyPreservesOperationFailure() {
    #expect(throws: AccessOperationFixtureError.operation) {
        let _: String = try SkillLibraryAccessCompletionPolicy().resolve(
            outcome: .failure(AccessOperationFixtureError.operation),
            releaseError: nil
        )
    }
}

@Test
func skillLibraryAccessCompletionPolicyPreservesReleaseFailureAfterSuccess() {
    #expect(throws: AccessOperationFixtureError.release) {
        let _: String = try SkillLibraryAccessCompletionPolicy().resolve(
            outcome: .success("completed"),
            releaseError: AccessOperationFixtureError.release
        )
    }
}

@Test
func skillLibraryAccessCompletionPolicyPreservesOperationAndReleaseFailures() {
    #expect(
        throws: SkillLibraryAccessCompletionFailure(
            operationFailure: "operation",
            releaseFailure: "release"
        )
    ) {
        let _: String = try SkillLibraryAccessCompletionPolicy().resolve(
            outcome: .failure(AccessOperationFixtureError.operation),
            releaseError: AccessOperationFixtureError.release
        )
    }
}
