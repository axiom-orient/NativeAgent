import EmbeddingCore
import Foundation
import LanguageModelCore
import LanguageModelRuntime
import LiteRTEmbeddingProvider
import LiteRTProvider

public struct LiteRTUnifiedReport: Codable, Sendable {
  public let runtimeVersion: String
  public let textBackend: String
  public let generatedText: String
  public let structuredJSON: String
  public let embedding: EmbeddingQualificationReport
  public let embeddingUsableAfterTextShutdown: Bool
  public let textCancellationJoined: Bool
  public let textReloadSucceeded: Bool
  public let closedTextAdmissionRejected: Bool
}

private actor StartReceipt {
  var observed = false
  var finished = false
  func record() { observed = true }
  func finish() { finished = true }
}

public enum LiteRTUnifiedQualification {
  private static func request(_ text: String, format: ModelOutputFormat = .text) -> ModelRequest {
    .init(sessionID: "synthetic-litert-qualification", messages: [.init(role: .user, content: text)],
      tools: [], outputFormat: format)
  }

  private static func turn(runtime: ModelRuntime, request: ModelRequest) async throws -> ModelTurn {
    let run = try await runtime.start(request)
    var result: ModelTurn?
    for try await event in run.events {
      if case .completed(let turn) = event { result = turn }
    }
    guard let result, !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      result.metadata["litertLMVersion"] == .string(LiteRTProvider.upstreamVersion)
    else { throw ModelGenerationFailure(.terminalMissing, "Native text result/version is missing.") }
    return result
  }

  private static func verifyCancellation(_ model: LiteRTTextModel) async throws -> Bool {
    let runtime = try await LiteRTProvider.loadRuntime(model)
    do {
      let receipt = StartReceipt()
      let run = try await runtime.start(request("Write a very long numbered list of 500 facts about the ocean. /no_think"))
      let consume = Task { () throws -> Bool in
        do {
          for try await event in run.events {
            if case .started = event { await receipt.record() }
          }
          await receipt.finish()
          return false
        } catch let failure as ModelGenerationFailure where failure.code == .cancelled {
          await receipt.finish()
          return true
        } catch {
          await receipt.finish()
          throw error
        }
      }
      while !(await receipt.observed), !(await receipt.finished) { await Task.yield() }
      guard await receipt.observed else {
        _ = try await consume.value
        throw ModelGenerationFailure(.terminalMissing, "Native text generation never started.")
      }
      try await Task.sleep(for: .milliseconds(150))
      await run.cancel()
      let joined = try await consume.value
      try await runtime.shutdown()
      return joined
    } catch {
      try await runtime.shutdown()
      throw error
    }
  }

  public static func run(textURL: URL, embeddingURL: URL, cache: URL, backend: LiteRTBackend = .cpu) async throws -> LiteRTUnifiedReport {
    let embedding = try await LiteRTEmbeddingModel.load(modelURL: embeddingURL, cacheDirectory: cache)
    let model = try LiteRTTextModel(id: "qualified-qwen3-06b", modelURL: textURL,
      backend: backend, contextWindowTokens: 512, cacheDirectoryURL: cache, sampling: .greedy)
    let runtime: ModelRuntime
    do { runtime = try await LiteRTProvider.loadRuntime(model) }
    catch { try await embedding.shutdown(); throw error }
    do {
      let plain = try await turn(runtime: runtime, request: request("Reply with the single word OK. /no_think"))
      let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["ok": .object(["type": .string("boolean"), "const": .bool(true)])]),
        "required": .array([.string("ok")]), "additionalProperties": .bool(false),
      ])
      let structured = try await turn(runtime: runtime,
        request: request("Return a JSON object with ok equal to true. /no_think", format: .jsonObject(schema: schema)))
      guard let object = try JSONSerialization.jsonObject(with: Data(structured.content.utf8)) as? [String: Any],
        object.count == 1, object["ok"] as? Bool == true
      else { throw ModelGenerationFailure(.malformedEvent, "Native constrained JSON did not satisfy the schema.") }
      try await runtime.shutdown()
      var closedRejected = false
      do { _ = try await runtime.start(request("Late input")) }
      catch let error as ModelRuntimeFailure where error.code == .closed { closedRejected = true }
      let stillUsable = try await embedding.embed(.query("텍스트 엔진 종료 뒤 임베딩"))
      let cancellationJoined = try await verifyCancellation(model)
      let reloaded = try await LiteRTProvider.loadRuntime(model)
      let reloadSucceeded: Bool
      do {
        let result = try await turn(runtime: reloaded, request: request("Say hello. /no_think"))
        reloadSucceeded = !result.content.isEmpty
        try await reloaded.shutdown()
      } catch {
        try await reloaded.shutdown()
        throw error
      }
      let embeddingReport = try await EmbeddingQualification.verifyAndClose(
        model: embedding, modelURL: embeddingURL, cacheDirectory: cache)
      guard embeddingReport.overflowRejected, embeddingReport.cancellationJoined,
        embeddingReport.reuseAfterCancellation, embeddingReport.closedAdmissionRejected, embeddingReport.reloadSucceeded,
        cancellationJoined, closedRejected else {
        throw ModelGenerationFailure(.malformedEvent, "Native cancellation or closed admission was not established.")
      }
      return .init(runtimeVersion: LiteRTProvider.upstreamVersion, textBackend: backend.rawValue, generatedText: plain.content,
        structuredJSON: structured.content, embedding: embeddingReport,
        embeddingUsableAfterTextShutdown: stillUsable.values.count == 256,
        textCancellationJoined: cancellationJoined, textReloadSucceeded: reloadSucceeded,
        closedTextAdmissionRejected: closedRejected)
    } catch {
      try await runtime.shutdown()
      try await embedding.shutdown()
      throw error
    }
  }
}
