import ASK
import Foundation
import LanguageModelCore
import NativeAgentDomain

/// Optional, stateless contract projection. ASK owns knowledge and mutation receipts;
/// the NativeAgent kernel owns authorization and the durable effect journal.
///
/// The host binds a typed query or an immutable plan before registering a tool.
/// Model arguments cannot change the workspace, command, or approved plan.
public struct ASKAgentTools: Sendable {
  private let client: ASKClient

  public init(client: ASKClient) { self.client = client }

  public func queryTool(
    _ query: ASKQuery, name: String = "ask_query",
    approvalPolicy: ApprovalPolicy = .requireApproval
  ) throws -> any ToolExecutor {
    try validateName(name)
    return BoundASKTool(
      client: client, operation: .query(query),
      definition: ToolDefinition(
        name: name, description: "Run the host-selected ASK read query.", capabilityID: "ask",
        inputSchema: .object([
          "type": .string("object"), "properties": .object([:]),
          "additionalProperties": .bool(false),
        ]), approvalPolicy: approvalPolicy, effect: .readOnly,
        metadata: [
          "askQuery": try json(query), "askConfiguration": try json(client.configuration),
          "replayPolicy": .string(query.replayPolicy.rawValue),
        ]))
  }

  /// Effect-free. The returned preview is shown before the Agent approval step.
  public func prepare(_ command: ASKCommand, name: String = "ask_apply") throws -> PreparedCommand {
    try validateName(name)
    let plan = try client.plan(command)
    let preview = try client.dryRun(plan)
    let definition = ToolDefinition(
      name: name, description: "Apply exactly this ASK plan after approval: " + preview.summary,
      capabilityID: "ask",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "actionID": .object([
            "type": .string("string"), "enum": .array([.string(plan.actionID)]),
          ])
        ]),
        "required": .array([.string("actionID")]), "additionalProperties": .bool(false),
      ]), approvalPolicy: .requireApproval, effect: .mutation,
      metadata: [
        "askPlan": try json(plan), "askPreview": try json(preview),
        "replayPolicy": .string(command.replayPolicy.rawValue),
      ])
    return PreparedCommand(
      plan: plan, preview: preview,
      tool: BoundASKTool(client: client, operation: .apply(plan), definition: definition))
  }

  public struct PreparedCommand: Sendable {
    public let plan: ASKCommandPlan
    public let preview: ASKDryRunResult
    /// Register with NativeAgent. Direct invocation is a trusted-host boundary,
    /// not an alternative authorization API or an approval receipt.
    public let tool: any ToolExecutor
  }

  private func validateName(_ name: String) throws {
    guard
      name.range(
        of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#,
        options: .regularExpression) != nil
    else {
      throw AgentError.invalidToolCall("Invalid ASK tool name.")
    }
  }
}

/// Preserves the original diagnostic while preventing automatic mutation replay.
/// ASK or the host must resolve its actionID before another apply is authorized.
public struct ASKApplyFailure: Error, EffectFailureClassifying, LocalizedError, Sendable {
  public let actionID: String
  public let underlyingError: any Error
  public var effectFailureCertainty: EffectFailureCertainty { .outcomeUnknown }
  public var errorDescription: String? { "ASK apply requires outcome resolution: \(actionID)." }
}

private struct BoundASKTool: ToolExecutor {
  enum Operation: Sendable {
    case query(ASKQuery)
    case apply(ASKCommandPlan)
  }
  let client: ASKClient
  let operation: Operation
  let definition: ToolDefinition

  func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
    // Approval is checked by the kernel before execute. Revalidate identity and exact
    // bound arguments here even when a trusted host invokes this executor directly.
    guard call.name == definition.name else {
      throw AgentError.invalidToolCall("ASK tool identity does not match the binding.")
    }
    let expected: JSONValue
    switch operation {
    case .query: expected = .object([:])
    case .apply(let plan): expected = .object(["actionID": .string(plan.actionID)])
    }
    guard call.arguments == expected else {
      throw AgentError.invalidToolCall("ASK arguments must match the immutable host binding.")
    }
    try Task.checkCancellation()
    switch operation {
    case .query(let query):
      return ToolResult(
        callID: call.id, toolName: call.name,
        output: try json(try await client.query(query)))
    case .apply(let plan):
      // Pure integrity check before crossing ASK's I/O boundary.
      _ = try client.dryRun(plan)
      do {
        let outcome = try await client.apply(plan)
        // Do not check cancellation after a committed effect. Return its receipt so
        // NativeAgent can journal it before cancellation stops future work.
        return ToolResult(
          callID: call.id, toolName: call.name, output: try json(outcome),
          metadata: [
            "actionID": .string(plan.actionID),
            "replayPolicy": .string(plan.command.replayPolicy.rawValue),
          ])
      } catch {
        throw ASKApplyFailure(actionID: plan.actionID, underlyingError: error)
      }
    }
  }
}

private func json<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
