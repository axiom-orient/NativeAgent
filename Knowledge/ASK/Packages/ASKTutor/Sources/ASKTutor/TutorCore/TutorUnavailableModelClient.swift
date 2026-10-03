import Foundation

public struct TutorUnavailableModelClient: TutorModelClient, Sendable {
    public init() {}

    public func explain(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
        throw ASKTutorError.model("No tutor model client configured for `explain`.")
    }

    public func solve(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
        throw ASKTutorError.model("No tutor model client configured for `solve`.")
    }

    public func makePracticeSet(_ request: TutorPracticeModelRequest) async throws -> TutorPracticeDraft {
        throw ASKTutorError.model("No tutor model client configured for `practice`.")
    }

    public func grade(_ request: TutorGradeModelRequest) async throws -> TutorGradeDraft {
        throw ASKTutorError.model("No tutor model client configured for `grade`.")
    }

    public func plan(_ request: TutorPlanModelRequest) async throws -> TutorPlanDraft {
        throw ASKTutorError.model("No tutor model client configured for `plan`.")
    }
}
