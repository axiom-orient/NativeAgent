import Foundation
import ASKTutor

public enum UnexpectedTestCall: Error { case invoked }

public func unexpectedCall<T>() async throws -> T {
    throw UnexpectedTestCall.invoked
}

public actor ScriptedModelClient: TutorModelClient {
    public var explainHandler: @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft
    public var solveHandler: @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft
    public var practiceHandler: @Sendable (TutorPracticeModelRequest) async throws -> TutorPracticeDraft
    public var gradeHandler: @Sendable (TutorGradeModelRequest) async throws -> TutorGradeDraft
    public var planHandler: @Sendable (TutorPlanModelRequest) async throws -> TutorPlanDraft

    public init(
        explainHandler: @escaping @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft,
        solveHandler: @escaping @Sendable (TutorExplainModelRequest) async throws -> TutorNarrativeDraft,
        practiceHandler: @escaping @Sendable (TutorPracticeModelRequest) async throws -> TutorPracticeDraft,
        gradeHandler: @escaping @Sendable (TutorGradeModelRequest) async throws -> TutorGradeDraft,
        planHandler: @escaping @Sendable (TutorPlanModelRequest) async throws -> TutorPlanDraft
    ) {
        self.explainHandler = explainHandler
        self.solveHandler = solveHandler
        self.practiceHandler = practiceHandler
        self.gradeHandler = gradeHandler
        self.planHandler = planHandler
    }

    public func explain(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft { try await explainHandler(request) }
    public func solve(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft { try await solveHandler(request) }
    public func makePracticeSet(_ request: TutorPracticeModelRequest) async throws -> TutorPracticeDraft { try await practiceHandler(request) }
    public func grade(_ request: TutorGradeModelRequest) async throws -> TutorGradeDraft { try await gradeHandler(request) }
    public func plan(_ request: TutorPlanModelRequest) async throws -> TutorPlanDraft { try await planHandler(request) }
}

public func makeRuntimeRoot(name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("asktutor-\(name)", isDirectory: true)
}

public func makeStoreRoot(name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("asktutor-store-\(name)", isDirectory: true)
}
