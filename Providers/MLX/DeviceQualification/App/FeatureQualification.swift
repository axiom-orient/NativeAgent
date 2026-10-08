import Foundation
import NativeAgent
import NativeAgentTools
import LanguageModelCore
import LanguageModelRuntime
import NativeAgentManager
import NativeAgentSkills
import NativeAgentMemory
import NativeAgentGoals
import NativeAgentEvolution
import NativeAgentConsensus
import ModelArtifactStore
import MLXProvider

struct MLXFeatureFailure: Error { let message: String }

enum MLXFeatureQualification {
  static func require(_ condition: Bool, _ message: String = "Qualification assertion failed") throws {
    guard condition else { throw MLXFeatureFailure(message: message) }
  }

  static func withRuntime(
    _ body: (MLXTextRuntime, MLXPreparedModel, ModelRuntime, URL) async throws -> Void
  ) async throws {
    let cache = try NativeAgentMLXDeviceQualificationRunner.qualificationRoot()
    let owner = MLXTextRuntime(store: try ModelArtifactStore(rootURL: cache),
      specificationsPersistenceURL: cache.appendingPathComponent("resolved-specifications.json"))
    let model = try MLXModel(
      repositoryID: NativeAgentMLXDeviceQualificationRunner.modelRepositoryID,
      revision: NativeAgentMLXDeviceQualificationRunner.modelRevision,
      extraEOSTokens: ["<|im_end|>"], disablesThinking: true,
      sampling: .init(temperature: 0, topP: 1, topK: 0, repetitionPenalty: 1))
    let prepared = try await owner.prepare(model)
    let nativeRuntime = try await owner.loadRuntime(prepared)
    let runtime = try ModelRuntime(id: .init(rawValue: "mlx.feature.trace"),
      client: MLXFeatureTraceClient(runtime: nativeRuntime), descriptor: nativeRuntime.modelDescriptor,
      cleanup: { try await nativeRuntime.shutdown() })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-features-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    do {
      try await body(owner, prepared, runtime, root)
      try await runtime.shutdown()
      try await owner.unload()
      print("NATIVE_AGENT_QWEN35_FEATURE_ARTIFACTS \(root.path)")
    } catch {
      print("NATIVE_AGENT_QWEN35_FEATURE_FAIL \(error)")
      try await runtime.shutdown()
      try await owner.unload()
      print("NATIVE_AGENT_QWEN35_FEATURE_ARTIFACTS \(root.path)")
      throw error
    }
  }

  static func files() async throws {
    try await withRuntime { _, _, runtime, root in
      let files = root.appendingPathComponent("files")
      try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
      let storage = AgentDataStore.directory(root.appendingPathComponent("storage")).storage
      let agent = try Agent(modelRuntime: runtime, storage: storage,
        instructions: "Use the supplied file tools for file operations. Do not invent tool results.",
        toolPacks: [FilesToolPack(rootURL: files)], approval: .allowAll)
      let first = try await agent.run("Use files.writeText to create proof.txt containing exactly LIVE_FILE_OK, then use files.readText to read it. Reply with its contents.")
      try require(first.status == .completed, "Files Agent did not complete")
      try require(first.output?.contains("LIVE_FILE_OK") == true, "Files output marker missing")
      try require(try String(contentsOf: files.appendingPathComponent("proof.txt"), encoding: .utf8) == "LIVE_FILE_OK", "File bytes mismatch")
      for name in ["files.writeText", "files.readText"] {
        try require(first.messages.contains { $0.role == .tool && $0.toolName == name && $0.metadata["isError"]?.boolValue == false }, "Missing real successful tool result: " + name)
      }
      let reloadedStorage = AgentDataStore.directory(root.appendingPathComponent("storage")).storage
      let persisted = try await reloadedStorage.session(id: first.sessionID)
      try require(persisted.messages == first.messages, "Tool transcript did not survive SQLite reload")
      let reloaded = try Agent(modelRuntime: runtime, storage: reloadedStorage)
      let next = try await reloaded.send("What exact text did we write? Reply only that text.", to: first.sessionID)
      try require(next.status == .completed && next.output?.contains("LIVE_FILE_OK") == true, "Tool conversation continuation failed")
      print("NATIVE_AGENT_QWEN35_FILES_PASS actualWrite=observed actualRead=observed durableReload=observed continuation=observed")
    }
  }
}

extension MLXFeatureQualification {
  static func manager() async throws {
    try await withRuntime { owner, prepared, runtime, root in
      let registry = try ModelProviderRegistry([MLXProviderConnector(runtime: owner, preparedModels: [prepared])])
      let manager = AgentManager(dataStore: .directory(root.appendingPathComponent("manager")), providers: registry, observer: MLXFeatureTraceObserver())
      _ = try await manager.createAgent(id: "live", name: "Live", provider: ModelProviderSelection(providerID: "mlx.text", modelID: "\(prepared.model.repositoryID)@\(prepared.model.revision)"), soul: "Answer precisely and briefly.", memory: "The user's favorite color is cobalt.")
      let library = try await manager.skillLibrary(agentID: "live")
      _ = try await library.addCustomTextSkill(name: "Tea", description: "Tea guidance", instructions: "When asked for the tea marker, answer TEA_SKILL_OK.", requiresSecret: false, requiresSecretDescription: "", homepage: "")
      let managed = try await manager.run(agentID: "live", input: "Load the Tea skill and report its tea marker.")
      print("NATIVE_AGENT_QWEN35_MANAGER_RESULT status=\(managed.status) output=\(managed.output ?? "nil") tools=\(managed.messages.compactMap(\.toolName))")
      try require(managed.status == .completed)
      try require(managed.output?.contains("TEA_SKILL_OK") == true)
      let color = try await manager.send(agentID: "live", input: "What is my favorite color?", to: managed.sessionID)
      try require(color.output?.lowercased().contains("cobalt") == true, "Persisted manager memory not recalled")
      try require(managed.messages.contains { $0.role == .tool && $0.toolName == "load_skill" && $0.metadata["isError"]?.boolValue == false })
      try require(managed.snapshot.metadata[AgentManager.soulSnapshotMetadataKey] != nil)
      try require(managed.snapshot.metadata[AgentManager.skillSnapshotMetadataKey] != nil)
      print("NATIVE_AGENT_QWEN35 manager: Soul, memory, pinned skill and real load_skill observed")

    }
  }
}

extension MLXFeatureQualification {
  static func memory() async throws {
    try await withRuntime { owner, prepared, runtime, root in
      let scope = MemoryScope(profileID: "live", userID: "user", sessionKey: "memory-session", namespace: "live")
      let memory = MemoryController(configuration: MemoryConfiguration(dataDirectory: root.appendingPathComponent("memory"), defaultProfileID: "live", defaultUserID: "user", namespace: "live"))
      let memoryStorage = AgentDataStore.directory(root.appendingPathComponent("memory-source")).storage
      let memoryAgent = try Agent(modelRuntime: runtime, storage: memoryStorage)
      _ = try await memoryAgent.run("I prefer jasmine tea every morning. Acknowledge briefly.", sessionID: "memory-session")
      _ = try await memory.sync(sessionID: "memory-session", from: memoryStorage)
      let consolidation = try await memory.consolidatePending(scope: scope, sessionID: "memory-session", provider: ModelRuntimeMemoryConsolidationProvider(modelRuntime: runtime))
      try require(consolidation.insertedRecords > 0)
      let matches = try await memory.search(scope: scope, query: "tea")
      try require(!matches.matches.isEmpty)
      print("NATIVE_AGENT_QWEN35 memory: real model consolidation and persisted search observed")

    }
  }
}

extension MLXFeatureQualification {
  static func goals() async throws {
    try await withRuntime { owner, prepared, runtime, root in
      let goalAgent = try Agent(modelRuntime: runtime, storage: AgentDataStore.directory(root.appendingPathComponent("goal-agent")).storage)
      let goalReport = try await GoalLoop(store: FileGoalSessionStore(rootURL: root.appendingPathComponent("goals")), runner: MLXLiveGoalRunner(agent: goalAgent), evaluator: ModelBackedGoalEvaluator(modelRuntime: runtime)).run(
        GoalRunRequest(goalID: "live", objective: "Report the sum of two and two", successCondition: "Output contains the correct result 4 and arithmetic evidence", maxTurns: 2, minScore: 0.5))
      try require(goalReport.status == .complete)
      try require(FileManager.default.fileExists(atPath: goalReport.storePath))
      print("NATIVE_AGENT_QWEN35 goals: real Agent turn, model evaluation and persisted completion observed")
    }
  }
}

extension MLXFeatureQualification {
  static func evolution() async throws {
    try await withRuntime { owner, prepared, runtime, root in
      let evolution = EvolutionLoop(generator: ModelBackedEvolutionCandidateGenerator(modelRuntime: runtime),
        evaluator: RunnerBackedEvolutionCandidateEvaluator(runner: ClosureEvolutionCandidateRunner { candidate, example in
          let turn = try await runtime.generate(ModelRequest(sessionID: "evolution-evaluation", messages: [.init(role: .system, content: candidate.content), .init(role: .user, content: example.input)], tools: []))
          return EvolutionRunOutput(exampleID: example.id, output: turn.content)
        }), store: FileEvolutionReportStore(rootURL: root.appendingPathComponent("evolution")))
      let evolutionReport = try await evolution.run(
        source: EvolutionArtifact(id: "source", name: "Instruction", content: "Answer arithmetic questions briefly."),
        dataset: EvolutionDataset(name: "arithmetic", examples: [EvolutionExample(id: "one", input: "2+2", expectedOutput: "4")]),
        config: EvolutionConfig(runID: "live", maxCandidates: 1))
      try require(evolutionReport.candidates.count == 1)
      try require(FileManager.default.fileExists(atPath: evolutionReport.storePath))
      print("NATIVE_AGENT_QWEN35 evolution: real candidate generation, baseline/candidate execution and persisted review report observed")

    }
  }
}

private struct MLXLiveGoalRunner: GoalTurnRunner {
  let agent: Agent
  func run(_ request: GoalTurnRequest) async throws -> GoalRunResult {
    let result: AgentRun
    if let sessionID = request.agentSessionID { result = try await agent.send(request.input, to: sessionID) }
    else { result = try await agent.run(request.input) }
    return GoalRunResult(sessionID: result.sessionID, status: result.status, output: result.output ?? "")
  }
}

extension MLXFeatureQualification {
  static func structuredOutput() async throws {
    try await withRuntime { _, _, runtime, _ in
      let schema: JSONValue = .object(["type": "object", "properties": .object([
        "ok": .object(["type": "boolean"])]), "required": .array(["ok"]), "additionalProperties": false])
      let turn = try await runtime.generate(ModelRequest(sessionID: "mlx-json",
        messages: [.init(role: .user, content: "Return an object with ok true.")],
        tools: [], outputFormat: .jsonObject(schema: schema)))
      let decoded = try JSONDecoder().decode([String: Bool].self, from: Data(turn.content.utf8))
      try require(decoded["ok"] == true)
      print("NATIVE_AGENT_QWEN35_JSON_PASS schema=validated")
    }
  }
}

private struct MLXFeatureTraceClient: ModelClient {
  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    let sequence = MLXTraceEventSequence(client: self, request: request)
    return AsyncThrowingStream(unfolding: { try await sequence.next() })
  }
  let runtime: ModelRuntime
  var providerID: String { runtime.modelDescriptor.providerID }
  var modelDescriptor: ModelDescriptor? { runtime.modelDescriptor }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    let turn = try await runtime.generate(request)
    print("NATIVE_AGENT_QWEN35_MODEL_TRACE session=\(request.sessionID) output=\(turn.content.prefix(6000))")
    return turn
  }
}

private actor MLXTraceEventSequence {
  let client: MLXFeatureTraceClient
  let request: ModelRequest
  var phase = 0
  init(client: MLXFeatureTraceClient, request: ModelRequest) {
    self.client = client; self.request = request
  }
  func next() async throws -> ModelEvent? {
    try Task.checkCancellation()
    switch phase {
    case 0: phase = 1; return .started(descriptor: client.modelDescriptor)
    case 1: phase = 2; return .completed(try await client.generate(request: request))
    default: return nil
    }
  }
}

private struct MLXFeatureTraceObserver: RuntimeObserver {
  func record(modelStream event: ModelInvocationStreamEvent) async {
    if case .completed(let turn) = event.event {
      print("NATIVE_AGENT_QWEN35_MANAGER_TRACE \(turn.content.prefix(6000)) tools=\(turn.toolCalls.map(\.name))")
    }
  }
  func record(effectDecision event: ToolEffectDecisionEvent) async {}
  func record(toolExecutionDuration event: ToolExecutionDurationEvent) async {}
}

extension MLXFeatureQualification {
  static func consensus() async throws {
    try await withRuntime { _, _, runtime, root in
      let queue = MLXFeatureRoleQueue()
      func driver(_ name: String) -> SessionConsensusRoleDriver {
        SessionConsensusRoleDriver(name: name) { input in
          try await queue.perform {
            let agent = try Agent(modelRuntime: runtime,
              storage: AgentDataStore.directory(root.appendingPathComponent(name)).storage,
              instructions: input.systemPrompt,
              configuration: AgentConfiguration(outputFormat: input.outputFormat))
            return try await agent.run(input.userPrompt, metadata: input.requestMetadata).snapshot
          }
        }
      }
      let triad = RoleBackedTriad(constructor: driver("constructor"),
        verifier: driver("verifier"), challenger: driver("challenger"))
      let report = try await BACEngine(config: BACConfig(maxRounds: 1), triad: triad.triad).run(
        problem: ProblemPacket(objective: "Explain a safe way to verify that 2+2 equals 4",
          observedIssue: "Need a concrete verification plan", constraints: ["No external actions needed"]))
      try require(report.rounds.count == 1)
      try require(report.final.decision == .accept,
        "Consensus did not accept the verification plan: \(report.final.reasons)")
      print("NATIVE_AGENT_QWEN35_CONSENSUS_PASS roles=3 nativeInference=serialized decision=accept")
    }
  }
}

/// The on-device resident has one inference slot. BAC roles retain separate
/// sessions while the host serializes their actual model work on that slot.
private actor MLXFeatureRoleQueue {
  private var tail: Task<Void, Never>?

  func perform(_ body: @escaping @Sendable () async throws -> SessionSnapshot) async throws -> SessionSnapshot {
    let previous = tail
    let task = Task {
      await previous?.value
      try Task.checkCancellation()
      return try await body()
    }
    tail = Task { _ = await task.result }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
  }
}


extension MLXFeatureQualification {
  static func structuredCancellationAndLimits() async throws {
    try await withRuntime { owner, _, runtime, _ in
      let schema: JSONValue = .object(["type": "object", "properties": .object([
        "text": .object(["type": "string"])]), "required": ["text"], "additionalProperties": false])
      func request(_ session: String, _ prompt: String, limits: ModelGenerationLimits = .default) -> ModelRequest {
        ModelRequest(sessionID: session, messages: [.init(role: .user, content: prompt)],
          tools: [], outputFormat: .jsonObject(schema: schema), limits: limits)
      }
      _ = try await runtime.generate(request("warm", "Put the word WARM in text."))
      let pending = Task { try await runtime.generate(request("cancel-json", "Write a detailed 2000-word garden story in text.")) }
      try await Task.sleep(for: .seconds(2))
      pending.cancel()
      do { _ = try await pending.value; throw MLXFeatureFailure(message: "Structured cancellation was not observed") }
      catch is CancellationError {}
      catch let error as ModelGenerationFailure { try require(error.code == .cancelled, "Cancellation returned: \(error)") }
      try await owner.unload()
      do {
        _ = try await runtime.generate(request("limited-json", "Put LIMIT in text.", limits: try ModelGenerationLimits(maxOutputBytes: 1)))
        throw MLXFeatureFailure(message: "Structured byte limit was not enforced")
      } catch let error as ModelGenerationFailure { try require(error.code == .limitExceeded, "Byte limit returned: \(error)") }
      let reused = try await runtime.generate(request("reused-json", "Put exactly REUSED_OK in text."))
      let decoded = try JSONDecoder().decode([String: String].self, from: Data(reused.content.utf8))
      try require(decoded["text"] == "REUSED_OK")
      print("NATIVE_AGENT_QWEN35_JSON_RECOVERY_PASS cancellation=observed ownerDrain=awaited byteLimit=enforced reuse=afterReload")
    }
  }
}
