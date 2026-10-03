import NativeAgentDomain
import NativeAgentExecution
import Foundation

public struct SessionCoordinatorGoalTurnRunner: GoalTurnRunner {
  private let coordinator: SessionCoordinator
  private let systemPrompt: String?
  private let titlePrefix: String
  private let metadata: [String: JSONValue]
  private let responseContinuation: ResponseContinuationPolicy

  public init(
    coordinator: SessionCoordinator,
    systemPrompt: String? = nil,
    titlePrefix: String = "NativeAgent Goal",
    metadata: [String: JSONValue] = [:],
    responseContinuation: ResponseContinuationPolicy = .disabled
  ) {
    self.coordinator = coordinator
    self.systemPrompt = systemPrompt
    self.titlePrefix = titlePrefix
    self.metadata = metadata
    self.responseContinuation = responseContinuation
  }

  public func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
    let requestMetadata: [String: JSONValue] = [
      "native-agent.goal.id": .string(request.goalID),
      "native-agent.goal.turn": .integer(Int64(request.turn)),
      "native-agent.goal.objective": .string(request.objective),
    ]

    do {
      let snapshot: SessionSnapshot
      if let sessionID = request.agentSessionID {
        snapshot = try await coordinator.continueSession(
          sessionID: sessionID,
          userPrompt: request.input,
          requestMetadata: requestMetadata,
          responseContinuation: responseContinuation
        )
      } else {
        var initialMetadata = metadata
        initialMetadata["native-agent.goal.id"] = .string(request.goalID)
        initialMetadata["native-agent.goal.objective"] = .string(request.objective)
        initialMetadata["native-agent.goal.success-condition"] = .string(request.successCondition)
        snapshot = try await coordinator.startSession(
          userPrompt: request.input,
          systemPrompt: systemPrompt,
          title: "\(titlePrefix): \(request.goalID)",
          metadata: initialMetadata,
          requestMetadata: requestMetadata,
          responseContinuation: responseContinuation
        )
      }
      return GoalRunResult(snapshot: snapshot)
    } catch {
      let runError = error
      guard let sessionID = request.agentSessionID else {
        throw runError
      }

      do {
        let snapshot = try await coordinator.loadSession(sessionID: sessionID)
        return GoalRunResult(
          snapshot: snapshot,
          errorMessage: runError.localizedDescription
        )
      } catch {
        throw SessionCoordinatorGoalRecoveryError(
          sessionID: sessionID,
          runFailure: runError.localizedDescription,
          recoveryFailure: error.localizedDescription
        )
      }
    }
  }
}
