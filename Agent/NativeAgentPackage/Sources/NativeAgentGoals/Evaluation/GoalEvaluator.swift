import NativeAgentDomain
import Foundation
import LanguageModelRuntime

public protocol GoalEvaluator: Sendable {
  func evaluate(session: GoalSession, result: GoalRunResult) async throws -> GoalEvaluation
}

public struct HeuristicGoalEvaluator: GoalEvaluator {
  public init() {}

  public func evaluate(session: GoalSession, result: GoalRunResult) async throws
    -> GoalEvaluation
  {
    let output = result.output.trimmedForNativeAgentGoal
    let explicit = explicitStatus(in: output)
    let failed = result.status == .failed || result.errorMessage != nil
    let waiting = result.status == .waiting || result.waitState != nil
    let blocked = waiting || explicit == "blocked"
    let hasConcreteEvidence = GoalEvidenceParser.hasConcreteEvidence(in: output)
    let coverage = keywordCoverage(
      required: [session.objective, session.successCondition].joined(separator: " "),
      observed: [output, result.errorMessage ?? ""].joined(separator: " ")
    )

    var score = coverage * Weights.keywordCoverage
    if result.status == .completed { score += Weights.completedStatus }
    if explicit == "complete" { score += Weights.explicitComplete }
    if hasConcreteEvidence { score += Weights.concreteEvidence }
    if explicit == "continue" { score += Weights.explicitContinue }
    if output.isEmpty { score -= Weights.emptyOutputPenalty }
    if waiting { score -= Weights.waitingPenalty }
    if failed { score -= Weights.failedPenalty }
    score = min(1, max(0, score))

    let satisfied =
      explicit == "complete" && hasConcreteEvidence && result.status == .completed && !failed
      && score >= session.minScore
    return GoalEvaluation(
      satisfied: satisfied,
      blocked: blocked,
      score: score,
      reason: reasonFor(
        explicit: explicit,
        satisfied: satisfied,
        blocked: blocked,
        failed: failed,
        waiting: waiting,
        hasConcreteEvidence: hasConcreteEvidence,
        score: score,
        result: result
      ),
      nextInstruction: nextInstruction(explicit: explicit, session: session, result: result),
      evaluator: "heuristic"
    )
  }

  private func reasonFor(
    explicit: String?,
    satisfied: Bool,
    blocked: Bool,
    failed: Bool,
    waiting: Bool,
    hasConcreteEvidence: Bool,
    score: Double,
    result: GoalRunResult
  ) -> String {
    if satisfied { return "goal satisfied by latest mobile agent session output" }
    if failed { return result.errorMessage ?? "latest mobile agent session failed" }
    if waiting { return "latest mobile agent session is waiting for host-side resolution" }
    if blocked { return "latest output marked the goal blocked" }
    if explicit == "complete" && !hasConcreteEvidence {
      return "completion marker found without concrete GOAL_EVIDENCE"
    }
    if explicit == "complete" {
      return String(format: "completion marker found, but score %.3f is below threshold", score)
    }
    if explicit == "continue" { return "latest output requested another goal iteration" }
    return String(format: "goal not satisfied yet; score %.3f", score)
  }

  private func nextInstruction(explicit: String?, session: GoalSession, result: GoalRunResult)
    -> String
  {
    if result.status == .waiting || result.waitState != nil {
      return "Report the host-side permission, signal, or time condition required to continue."
    }
    if result.status == .failed {
      return "Diagnose the failure, reduce scope, and retry the smallest mobile-safe next action."
    }
    if explicit == "blocked" {
      return
        "Stop broad changes and summarize the blocker with evidence needed from the host app or user."
    }
    if !session.latestInstruction.isEmpty { return session.latestInstruction }
    return
      "Continue toward the objective, use only mobile-safe tools, gather concrete evidence, and end with GOAL_STATUS."
  }

  private func explicitStatus(in output: String) -> String? {
    for line in output.components(separatedBy: .newlines).reversed() {
      let clean = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard clean.hasPrefix("goal_status:") else { continue }
      let value = clean.dropFirst("goal_status:".count).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if value.contains("<") || value.contains("|") { continue }
      let token =
        value.components(separatedBy: CharacterSet.alphanumerics.inverted).first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if token == "complete" { return "complete" }
      if token == "blocked" { return "blocked" }
      if token == "continue" { return "continue" }
    }
    return nil
  }

  private func keywordCoverage(required: String, observed: String) -> Double {
    let requiredTokens = Set(tokens(required).filter { $0.count >= 4 })
    if requiredTokens.isEmpty { return observed.trimmedForNativeAgentGoal.isEmpty ? 0 : 0.45 }
    let observedTokens = Set(tokens(observed))
    let hits = requiredTokens.filter { observedTokens.contains($0) }.count
    return Double(hits) / Double(requiredTokens.count)
  }

  private func tokens(_ text: String) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .map { $0.trimmedForNativeAgentGoal }
      .filter { !$0.isEmpty && !Self.stopWords.contains($0) }
  }

  private static let stopWords: Set<String> = [
    "the", "and", "for", "with", "that", "this", "from", "until", "without", "when", "what",
    "should", "must", "have", "true",
  ]

  private enum Weights {
    static let keywordCoverage = 0.58
    static let completedStatus = 0.22
    static let explicitComplete = 0.16
    static let concreteEvidence = 0.08
    static let explicitContinue = 0.03
    static let emptyOutputPenalty = 0.16
    static let waitingPenalty = 0.12
    static let failedPenalty = 0.35
  }
}

public struct ModelBackedGoalEvaluator: GoalEvaluator {
  private let modelRuntime: ModelRuntime
  private let baseline: HeuristicGoalEvaluator

  public init(
    modelRuntime: ModelRuntime,
    baseline: HeuristicGoalEvaluator = HeuristicGoalEvaluator()
  ) {
    self.modelRuntime = modelRuntime
    self.baseline = baseline
  }

  public func evaluate(session: GoalSession, result: GoalRunResult) async throws
    -> GoalEvaluation
  {
    let baselineEvaluation = try await baseline.evaluate(session: session, result: result)
    let request = ModelRequest(
      sessionID: "goal-eval-\(session.goalID)-\(session.nextTurn)",
      modelID: modelRuntime.modelDescriptor.id,
      messages: [
        AgentMessage(
          role: .system,
          content: "You are a strict NativeAgent mobile goal completion evaluator. Return JSON only."),
        AgentMessage(
          role: .user,
          content: prompt(session: session, result: result, baseline: baselineEvaluation)),
      ],
      tools: [],
      metadata: ["native-agent.goal.evaluator": .bool(true)],
      outputFormat: modelRuntime.modelDescriptor.capabilities.contains(.structuredOutput)
        ? .jsonObject(schema: Self.responseSchema) : .text
    )
    let turn = try await modelRuntime.generate(request)
    let decoded = try GoalJudgeResponseDecoder().decode(turn.content)
    let runtimeAllowsCompletion =
      result.status == .completed
      && result.errorMessage == nil
      && result.waitState == nil
      && GoalEvidenceParser.hasConcreteEvidence(in: result.output)
    let score = min(1, max(0, decoded.score))
    let satisfied = decoded.satisfied && runtimeAllowsCompletion && score >= session.minScore
    return GoalEvaluation(
      satisfied: satisfied,
      blocked: decoded.blocked || result.status == .waiting || result.waitState != nil,
      score: score,
      reason: decoded.reason.trimmedForNativeAgentGoal.isEmpty ? baselineEvaluation.reason : decoded.reason,
      nextInstruction: decoded.nextInstruction.trimmedForNativeAgentGoal.isEmpty
        ? baselineEvaluation.nextInstruction : decoded.nextInstruction,
      evaluator: "model"
    )
  }

  private static let responseSchema: JSONValue = .object([
    "type": "object", "additionalProperties": false,
    "required": .array(["satisfied", "blocked", "score", "reason", "next_instruction"]),
    "properties": .object([
      "satisfied": .object(["type": "boolean"]),
      "blocked": .object(["type": "boolean"]),
      "score": .object(["type": "number", "minimum": 0, "maximum": 1]),
      "reason": .object(["type": "string"]),
      "next_instruction": .object(["type": "string"])
    ])
  ])

  private func prompt(
    session: GoalSession, result: GoalRunResult, baseline: GoalEvaluation
  ) -> String {
    let recent = session.turns.suffix(6).map { item in
      "turn \(item.turn): score=\(String(format: "%.3f", item.score)) satisfied=\(item.satisfied) blocked=\(item.blocked) reason=\(item.reason)"
    }.joined(separator: "\n")
    return """
      Decide whether the active NativeAgent mobile /goal is complete after the latest mobile-agent turn.
      Return one JSON object with these fields:
      satisfied (boolean), blocked (boolean), score (number), reason (string), next_instruction (string).

      Rules:
      - satisfied=true only if the objective and success condition are supported by concrete evidence in the latest output.
      - Do not mark complete merely because the worker claims completion.
      - If status is waiting, blocked=true.
      - If the mobile session failed, satisfied=false.
      - score must be 0.0...1.0 and reflect evidence strength: 0.0 means no supporting evidence, 1.0 means the success condition is fully demonstrated.
      - Consider mobile constraints: sandboxed files, host-owned permissions, and interruptible lifecycle.

      Objective:
      \(session.objective)

      Success condition:
      \(session.successCondition.isEmpty ? session.objective : session.successCondition)

      Previous evaluations:
      \(recent.isEmpty ? "(none)" : recent)

      Runtime status: \(result.status.rawValue)
      Runtime wait: \(result.waitState?.kind.rawValue ?? "none")
      Runtime failure: \(result.errorMessage ?? "")
      Baseline evaluator: score=\(baseline.score), satisfied=\(baseline.satisfied), blocked=\(baseline.blocked), reason=\(baseline.reason)

      Latest output:
      \(result.output)
      """
  }

}

enum GoalEvidenceParser {
  static func hasConcreteEvidence(in output: String) -> Bool {
    let lines = output.components(separatedBy: .newlines)
    for index in lines.indices {
      let clean = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      let lowered = clean.lowercased()
      guard lowered.hasPrefix("goal_evidence:") else { continue }

      let inline = String(clean.dropFirst("GOAL_EVIDENCE:".count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if isConcreteEvidenceLine(inline) { return true }

      let tail = lines.index(after: index)..<lines.endIndex
      for tailIndex in tail {
        let candidate = lines[tailIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerCandidate = candidate.lowercased()
        if lowerCandidate.hasPrefix("goal_status:") || lowerCandidate.hasPrefix("goal_reason:") {
          return false
        }
        if isConcreteEvidenceLine(candidate) { return true }
      }
      return false
    }
    return false
  }

  private static func isConcreteEvidenceLine(_ raw: String) -> Bool {
    let stripped =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard stripped.count >= 4 else { return false }
    let lowered = stripped.lowercased()
    if lowered == "none" || lowered == "n/a" || lowered == "unknown" { return false }
    if lowered.contains("<") || lowered.contains(">") { return false }
    if lowered.contains("no evidence") || lowered.contains("without evidence") { return false }
    return true
  }
}
