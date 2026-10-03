import NativeAgentDomain
import Foundation
import LanguageModelRuntime

public struct ModelBackedEvolutionCandidateGenerator: EvolutionCandidateGenerator {
  private struct CandidateEnvelope: Decodable {
    var candidates: [CandidatePayload]
  }

  private struct CandidatePayload: Decodable {
    var id: String?
    var title: String?
    var content: String
    var rationale: String?
    var metadataJSON: String?
  }

  private let modelRuntime: ModelRuntime
  private let systemPrompt: String
  private let requestMetadata: [String: JSONValue]
  private let createdAt: @Sendable () -> Date

  public init(
    modelRuntime: ModelRuntime,
    systemPrompt: String = ModelBackedEvolutionCandidateGenerator.defaultSystemPrompt,
    requestMetadata: [String: JSONValue] = [:],
    createdAt: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.modelRuntime = modelRuntime
    self.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    self.requestMetadata = requestMetadata
    self.createdAt = createdAt
  }

  public func generateCandidates(
    source: EvolutionArtifact,
    dataset: EvolutionDataset,
    config: EvolutionConfig
  ) async throws -> [EvolutionCandidate] {
    let request = ModelRequest(
      sessionID: "native-agent-evolution-\(config.runID)",
      modelID: modelRuntime.modelDescriptor.id,
      messages: [
        AgentMessage(role: .system, content: systemPrompt, createdAt: createdAt()),
        AgentMessage(
          role: .user, content: userPrompt(source: source, dataset: dataset, config: config),
          createdAt: createdAt()),
      ],
      tools: [],
      metadata: requestMetadata.merging([
        "native-agent.evolution.run-id": .string(config.runID),
        "native-agent.evolution.source-id": .string(source.id),
        "native-agent.evolution.dataset": .string(dataset.name),
        "native-agent.evolution.max-candidates": .integer(Int64(config.maxCandidates)),
      ]) { current, _ in current },
      outputFormat: modelRuntime.modelDescriptor.capabilities.contains(.structuredOutput)
        ? .jsonObject(schema: Self.candidateSchema(maxCandidates: config.maxCandidates)) : .text
    )
    let turn: ModelTurn
    do {
      turn = try await modelRuntime.generate(request)
    } catch let failure as ModelGenerationFailure where failure.code == .malformedEvent {
      throw EvolutionError.invalidCandidate("model-backed generator returned invalid structured output: \(failure.message)")
    }
    return try Self.parseCandidates(
      from: turn.content,
      source: source,
      maxCandidates: config.maxCandidates
    )
  }

  private static func candidateSchema(maxCandidates: Int) -> JSONValue {
    let text: JSONValue = .object(["type": "string", "minLength": 1])
    return .object(["type": "object", "properties": .object([
      "candidates": .object(["type": "array", "minItems": 1,
        "maxItems": .integer(Int64(maxCandidates)), "items": .object([
          "type": "object", "properties": .object([
            "id": text, "title": text, "content": text, "rationale": text,
            "metadataJSON": .object(["type": "string", "description": "A JSON-encoded object containing arbitrary candidate metadata. Use {} when empty."])
          ]), "required": .array(["id", "title", "content", "rationale", "metadataJSON"]),
          "additionalProperties": false])])
    ]), "required": .array(["candidates"]), "additionalProperties": false])
  }

  public static let defaultSystemPrompt = """
    You generate safe NativeAgent mobile evolution candidates.
    Return only strict JSON, starting with { and ending with }. Never use markdown code fences.
    Return at most the requested number of candidates. Use this shape:
    {"candidates":[{"id":"short-id","title":"title","content":"full replacement artifact","rationale":"why it improves mobile behavior","metadataJSON":"{}"}]}
    Constraints:
    - Keep the source artifact's purpose intact.
    - Preserve host-owned approval, permission, sandbox, signal, and time-wait semantics.
    - Do not add instructions that bypass approval, mutate silently, or assume desktop-only tools.
    - Prefer small reversible improvements.
    - Use metadataJSON "{}" unless candidate metadata was explicitly requested. Put your explanation only in rationale.
    - If metadata is requested, metadataJSON must be a complete JSON object encoded as one string.
    """

  static func parseCandidates(
    from content: String,
    source: EvolutionArtifact,
    maxCandidates: Int
  ) throws -> [EvolutionCandidate] {
    let data = Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    let envelope: CandidateEnvelope
    do {
      envelope = try JSONDecoder.nativeAgent().decode(CandidateEnvelope.self, from: data)
    } catch {
      throw EvolutionError.invalidCandidate(
        "model-backed generator expected strict JSON candidate envelope: \(error.localizedDescription)"
      )
    }

    guard maxCandidates >= EvolutionConfig.minimumCandidates else {
      throw EvolutionError.invalidCandidate("maxCandidates must satisfy EvolutionConfig")
    }
    let candidates = try envelope.candidates.prefix(maxCandidates).enumerated().map {
      index, payload in
      let id = payload.id?.nonEmptyForNativeAgentEvolution ?? "model-candidate-\(index + 1)"
      let title = payload.title?.nonEmptyForNativeAgentEvolution ?? "Model candidate \(index + 1)"
      var metadata: [String: JSONValue] = [:]
      if let encoded = payload.metadataJSON {
        do { metadata = try JSONDecoder().decode([String: JSONValue].self, from: Data(encoded.utf8)) }
        catch { throw EvolutionError.invalidCandidate("candidate metadataJSON must encode a JSON object") }
      }
      metadata["generator"] = .string("model-backed")
      metadata["source_id"] = .string(source.id)
      return EvolutionCandidate(
        id: id,
        title: title,
        content: payload.content,
        rationale: payload.rationale ?? "model-backed candidate",
        metadata: metadata
      )
    }
    guard !candidates.isEmpty else { throw EvolutionError.noCandidates }
    return Array(candidates)
  }

  private func userPrompt(
    source: EvolutionArtifact,
    dataset: EvolutionDataset,
    config: EvolutionConfig
  ) -> String {
    let examples = dataset.examples.map { example in
      """
      - id: \(example.id)
        split: \(example.split.rawValue)
        input: \(example.input)
        expected_output: \(example.expectedOutput)
      """
    }.joined(separator: "\n")

    return """
      Generate up to \(config.maxCandidates) improved candidates for this NativeAgent mobile artifact.

      Source ID: \(source.id)
      Source name: \(source.name)

      Current artifact:
      ```
      \(source.content)
      ```

      Evaluation dataset:
      \(examples.isEmpty ? "(none)" : examples)

      Improvement gate:
      - Minimum validation improvement: \(config.minImprovement)
      - Require holdout no regression: \(config.requireHoldoutNoRegression)

      Return strict JSON only.
      """
  }
}
