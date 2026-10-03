import Foundation

public protocol TutorModelClient: Sendable {
    func explain(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft
    func solve(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft
    func makePracticeSet(_ request: TutorPracticeModelRequest) async throws -> TutorPracticeDraft
    func grade(_ request: TutorGradeModelRequest) async throws -> TutorGradeDraft
    func plan(_ request: TutorPlanModelRequest) async throws -> TutorPlanDraft
}
