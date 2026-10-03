import Foundation
import NativeAgentTestSupport
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentGoals
@testable import NativeAgentStore

@Test
func goalRunResultRejectsContradictoryWaitState() throws {
  let missingWait = GoalRunResult(
    sessionID: "session",
    status: .waiting,
    output: "waiting"
  )
  #expect(throws: AgentError.self) {
    try missingWait.validateState()
  }

  let unexpectedWait = GoalRunResult(
    sessionID: "session",
    status: .completed,
    output: "done",
    waitState: .signal(identifier: "signal")
  )
  #expect(throws: AgentError.self) {
    try unexpectedWait.validateState()
  }

}

@Test
func goalSessionEventsProduceIndependentStateSnapshots() {
  let initial = GoalSession(
    goalID: "event-goal",
    objective: "preserve event history",
    status: .blocked,
    maxTurns: 3,
    minScore: 0.4,
    maxStaleTurns: 2,
    minProgressDelta: 0.11,
    agentSessionID: "original"
  )
  let record = GoalTurnRecord(
    turn: 1,
    sessionID: "resumed-agent",
    status: .completed,
    output: "evidence",
    evaluation: GoalEvaluation(satisfied: false, score: 0.5, reason: "continue")
  )

  let recorded = initial.applying(.appended(record))
  let resumed = recorded.applying(
    .resumed(
      maxAdditionalTurns: 4,
      minScore: 0.8,
      maxStaleTurns: 5,
      minProgressDelta: 0.23
    ))
  let exhausted = resumed.applying(.turnBudgetExhausted)

  #expect(initial.status == .blocked)
  #expect(initial.turns.isEmpty)
  #expect(initial.agentSessionID == "original")
  #expect(recorded.status == .blocked)
  #expect(recorded.turns == [record])
  #expect(recorded.agentSessionID == "resumed-agent")
  #expect(recorded.lastReason == "continue")
  #expect(resumed.status == .active)
  #expect(resumed.maxTurns == 5)
  #expect(resumed.minScore == 0.8)
  #expect(resumed.maxStaleTurns == 5)
  #expect(resumed.minProgressDelta == 0.23)
  #expect(exhausted.status == .budgetLimited)
  #expect(exhausted.lastReason == "goal reached maxTurns=5")
}

@Test
func heuristicGoalEvaluatorRequiresExplicitCompleteAndCompletedSession() async throws {
  let session = GoalSession(
    goalID: "mobile-goal",
    objective: "collect mobile approval evidence",
    successCondition: "approval evidence is reported",
    minScore: 0.2
  )
  let result = GoalRunResult(
    sessionID: "session-1",
    status: .completed,
    output:
      "Collected mobile approval evidence.\nGOAL_EVIDENCE:\n- approval evidence reported\nGOAL_STATUS: complete\nGOAL_REASON: done"
  )

  let evaluation = try await HeuristicGoalEvaluator().evaluate(session: session, result: result)

  #expect(evaluation.satisfied)
  #expect(evaluation.blocked == false)
  #expect(evaluation.score >= session.minScore)
}

@Test
func heuristicGoalEvaluatorRejectsCompletionWithoutConcreteEvidence() async throws {
  let session = GoalSession(
    goalID: "mobile-goal-no-evidence",
    objective: "collect mobile approval evidence",
    successCondition: "approval evidence is reported",
    minScore: 0.2
  )
  let result = GoalRunResult(
    sessionID: "session-1",
    status: .completed,
    output: "Collected mobile approval evidence.\nGOAL_STATUS: complete\nGOAL_REASON: claimed done"
  )

  let evaluation = try await HeuristicGoalEvaluator().evaluate(session: session, result: result)

  #expect(evaluation.satisfied == false)
  #expect(evaluation.reason.contains("GOAL_EVIDENCE"))
}

@Test
func goalTurnPlannerRendersBlankPreviousOutputAsNone() throws {
  let firstTurnSession = GoalSession(
    goalID: "no-previous",
    objective: "start without previous output"
  )
  let firstTurnRequest = try GoalTurnPlanner().makeTurnRequest(session: firstTurnSession)
  let firstTurnLines = firstTurnRequest.input.components(separatedBy: .newlines)
   #expect(firstTurnLines.contains("Previous result: (none)"))

  let blankPreviousSession = GoalSession(
    goalID: "blank-previous",
    objective: "continue after blank output",
    turns: [
      GoalTurnRecord(
        turn: 1,
        sessionID: "session-1",
        status: .completed,
        output: " \n\t ",
        evaluation: GoalEvaluation(satisfied: false)
      )
    ]
  )

  let request = try GoalTurnPlanner().makeTurnRequest(session: blankPreviousSession)
  let lines = request.input.components(separatedBy: .newlines)
  #expect(lines.contains("Previous result: (none)"))
}

@Test
func modelBackedGoalEvaluatorDecodesFencedJSONWithTextAndStringBraces() async throws {
  let model = ScriptedModelClient(modelDescriptor: ModelDescriptor(
    id: "text-judge", providerID: "provider.test.scripted",
    capabilities: [.textInput, .textOutput], contextWindowTokens: 10000), scriptedTurns: [
    ModelTurn(
      content: """
        I checked "the result first: {"note":"not the judge schema"}

        ```json
        {"satisfied":true,"blocked":false,"score":0.91,"reason":"evidence contains } inside text","next_instruction":"done after } marker"}
        ```
        """
    )
  ])
  let evaluator = ModelBackedGoalEvaluator(modelRuntime: try makeTestModelRuntime(model))
  let session = GoalSession(
    goalID: "model-json",
    objective: "collect evidence",
    successCondition: "evidence collected",
    minScore: 0.2
  )
  let result = GoalRunResult(
    sessionID: "session-1",
    status: .completed,
    output: """
      Evidence collected.
      GOAL_EVIDENCE:
      - evidence collected from runtime output
      GOAL_STATUS: complete
      GOAL_REASON: done
      """
  )

  let evaluation = try await evaluator.evaluate(session: session, result: result)

  #expect(evaluation.satisfied)
  #expect(evaluation.score == 0.91)
  #expect(evaluation.reason == "evidence contains } inside text")
  #expect(evaluation.nextInstruction == "done after } marker")
}
