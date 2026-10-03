import ASK
import ASKAgentTools
import Foundation
import LanguageModelCore
import NativeAgentDomain
import Testing

@Suite("ASK optional tools: real ASK client, no substitute storage")
struct ASKAgentToolsTests {
  @Test func planningIsDeterministicEffectFreeAndAlwaysRequiresApproval() throws {
    let workspace = root()
    let tools = ASKAgentTools(client: client(workspace))
    let first = try tools.prepare(command())
    let second = try tools.prepare(command())
    #expect(first.plan == second.plan)
    #expect(first.preview.actionID == first.plan.actionID)
    #expect(first.tool.definition.approvalPolicy == .requireApproval)
    #expect(first.tool.definition.effect == .mutation)
    #expect(first.tool.definition.metadata["askPlan"] != nil)
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test func changedActionOrExtraArgumentsCannotReachASK() async throws {
    let workspace = root()
    let prepared = try ASKAgentTools(client: client(workspace)).prepare(command())
    for arguments: JSONValue in [
      .object(["actionID": .string("different")]),
      .object(["actionID": .string(prepared.plan.actionID), "workspace": .string("other")]),
      .object([:]),
    ] {
      await #expect(throws: AgentError.self) {
        _ = try await prepared.tool.execute(
          call: .init(name: "ask_apply", arguments: arguments), context: context(workspace))
      }
    }
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test func changedNameCannotReachASK() async throws {
    let workspace = root()
    let prepared = try ASKAgentTools(client: client(workspace)).prepare(command())
    await #expect(throws: AgentError.self) {
      _ = try await prepared.tool.execute(
        call: .init(
          name: "different",
          arguments:
            .object(["actionID": .string(prepared.plan.actionID)])), context: context(workspace))
    }
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test func readonlyMarkdownQueryUsesASKAndDoesNotCreateWorkspace() async throws {
    let workspace = root()
    let query = ASKQuery.markdownPage(.init(markdown: "# Actual ASK\n\nBody.", documentID: "doc-1"))
    let tool = try ASKAgentTools(client: client(workspace)).queryTool(query)
    #expect(tool.definition.effect == .readOnly)
    #expect(tool.definition.approvalPolicy == .requireApproval)
    let result = try await tool.execute(
      call: .init(name: "ask_query", arguments: .object([:])),
      context: context(workspace))
    let expected = try await client(workspace).query(query)
    let decoded = try JSONDecoder().decode(
      ASKQueryResult.self, from: JSONEncoder().encode(result.output))
    #expect(decoded == expected)
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test func actualApplyReturnsCanonicalOutcomeAndReceiptIdentity() async throws {
    let workspace = root()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let prepared = try ASKAgentTools(client: client(workspace)).prepare(command())
    let result = try await prepared.tool.execute(
      call: .init(
        id: "call-1", name: "ask_apply",
        arguments: .object(["actionID": .string(prepared.plan.actionID)])),
      context: context(workspace))
    #expect(result.callID == "call-1")
    #expect(!result.isError)
    #expect(result.metadata["actionID"] == .string(prepared.plan.actionID))
    let outcome = try JSONDecoder().decode(
      ASKApplyOutcome.self, from: JSONEncoder().encode(result.output))
    guard case .workspaceApplied(let applied) = outcome else {
      Issue.record("Missing canonical outcome")
      return
    }
    #expect(applied.actionID == prepared.plan.actionID)
    #expect(FileManager.default.fileExists(atPath: workspace.path))
    // Re-open ASK; the adapter has no replica or private store to satisfy this query.
    _ = try await client(workspace).query(.pendingWork(.init()))
  }

  @Test func cancellationBeforeEffectDoesNotCreateWorkspace() async throws {
    let workspace = root()
    let prepared = try ASKAgentTools(client: client(workspace)).prepare(command())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await prepared.tool.execute(
        call: .init(
          name: "ask_apply",
          arguments: .object(["actionID": .string(prepared.plan.actionID)])),
        context: context(workspace))
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test func invalidNamesFailBeforePlanning() throws {
    let tools = ASKAgentTools(client: client(root()))
    for name in ["", "bad name", "9invalid", String(repeating: "x", count: 65)] {
      #expect(throws: AgentError.self) { _ = try tools.prepare(command(), name: name) }
    }
  }

  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ask-agent-" + UUID().uuidString)
  }
  private func client(_ root: URL) -> ASKClient {
    ASKClient(configuration: .init(workspaceURL: root))
  }
  private func command() -> ASKCommand { .quickStart(.init(requestedAt: "2026-09-20T00:00:00Z")) }
  private func context(_ root: URL) -> ToolExecutionContext {
    .init(sessionID: "test", sessionDirectoryURL: root, sandboxRootURL: root)
  }
}
