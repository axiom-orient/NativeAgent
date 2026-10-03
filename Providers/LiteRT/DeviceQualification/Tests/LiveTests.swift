import XCTest
import LiteRTProvider
import LanguageModelCore
final class LiveTests: XCTestCase {
  func testNativeQwen() async throws {
    let path = Bundle.main.bundleURL.appendingPathComponent("Qwen3.5-0.8B_int8.litertlm")
    let model = try LiteRTTextModel(id: "qwen3.5-0.8b", modelURL: path, backend: .cpu, contextWindowTokens: 2048, cacheDirectoryURL: FileManager.default.temporaryDirectory, sampling: .greedy)
    print("LITERT_LIVE loading=cpu")
    let runtime = try await LiteRTProvider.loadRuntime(model)
    do {
      let turn = try await runtime.generate(ModelRequest(sessionID: "live", messages: [.init(role: .user, content: "Reply exactly LITERT_OK")], tools: []))
      print("LITERT_LIVE output=\(turn.content)")
      XCTAssertTrue(turn.content.contains("LITERT_OK"))
      try await runtime.shutdown()
      print("LITERT_LIVE cleanup=closed")
    } catch { try await runtime.shutdown(); throw error }
  }
}

extension LiveTests {
  func testNativeStructuredToolsAndCancellation() async throws {
    let path = Bundle.main.bundleURL.appendingPathComponent("Qwen3.5-0.8B_int8.litertlm")
    let model = try LiteRTTextModel(id: "qwen3.5-0.8b", modelURL: path, backend: .cpu, contextWindowTokens: 2048, cacheDirectoryURL: FileManager.default.temporaryDirectory, sampling: .greedy)
    let runtime = try await LiteRTProvider.loadRuntime(model)
    do {
      let schema: JSONValue = .object(["type": "object", "properties": .object(["answer": .object(["type": "integer"])]), "required": ["answer"], "additionalProperties": false])
      let json = try await runtime.generate(ModelRequest(sessionID: "json", messages: [.init(role: .user, content: "Respond with a JSON object using the key answer. Calculate the sum of two and two.")], tools: [], outputFormat: .jsonObject(schema: schema)))
      let value = try JSONSerialization.jsonObject(with: Data(json.content.utf8)) as? [String: Int]
      XCTAssertEqual(value?["answer"], 4)
      print("LITERT_STRUCTURED output=\(json.content)")
      let tool = ModelTool(name: "write_proof", description: "Write the requested text to the qualification file.", inputSchema: .object(["type": "object", "properties": .object(["text": .object(["type": "string"])]), "required": ["text"], "additionalProperties": false]))
      let user = AgentMessage(role: .user, content: "Call write_proof with text LITERT_TOOL_OK.")
      XCTAssertFalse(runtime.modelDescriptor.capabilities.contains(.toolCalls))
      do {
        _ = try await runtime.generate(ModelRequest(sessionID: "tool", messages: [user], tools: [tool]))
        XCTFail("Artifact without a tool template must reject tools before native generation")
      } catch let failure as ModelGenerationFailure {
        XCTAssertEqual(failure.code, .policyViolation)
      }
      let continued = try await runtime.generate(ModelRequest(sessionID: "history", messages: [.init(role: .user, content: "Remember my marker is COBALT."), .init(role: .assistant, content: "Your marker is COBALT."), .init(role: .user, content: "What is my marker? Reply with only the marker.")], tools: []))
      XCTAssertTrue(continued.content.contains("COBALT"))
      print("LITERT_HISTORY output=\(continued.content) toolCapability=explicitlyUnavailable")
      let pending = Task { try await runtime.generate(ModelRequest(sessionID: "cancel", messages: [.init(role: .user, content: "Write a long detailed story of 2000 words about a garden.")], tools: [])) }
      try await Task.sleep(for: .milliseconds(500))
      pending.cancel()
      do { _ = try await pending.value; XCTFail("Cancellation did not interrupt generation") }
      catch { XCTAssertTrue(error is CancellationError || String(describing: error).lowercased().contains("cancel")) }
      let reuseRequest = ModelRequest(sessionID: "reuse", messages: [.init(role: .user, content: "Reply exactly REUSED_OK")], tools: [])
      do { _ = try await runtime.generate(reuseRequest); XCTFail("Cancelled engine must reject reuse") }
      catch let failure as ModelGenerationFailure { XCTAssertEqual(failure.code, .sourceUnavailable) }
      try await runtime.shutdown()
      let fresh = try await LiteRTProvider.loadRuntime(model)
      do {
        let reused = try await fresh.generate(reuseRequest)
        XCTAssertTrue(reused.content.contains("REUSED_OK"))
        print("LITERT_CANCEL invalidated=observed explicitReload=\(reused.content)")
        try await fresh.shutdown()
      } catch { try await fresh.shutdown(); throw error }
      try await runtime.shutdown()
    } catch { try await runtime.shutdown(); throw error }
  }
}
