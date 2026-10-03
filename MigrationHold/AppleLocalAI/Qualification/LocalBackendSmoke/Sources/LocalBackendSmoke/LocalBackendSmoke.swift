import AppleLocalAI
import Foundation
import FoundationModels
import NativeAgent
import NativeAgentManager
import LanguageModelRuntime
import NativeAgentProviderAppleLocalAI
import LiteRTProvider

/// Real local-file inference only. No fixture, downloads, fallback, or server.
@main struct LocalBackendSmoke {
  @MainActor static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 else {
      throw SmokeError.arguments("Usage: LocalBackendSmoke MODEL.litertlm NEW_STATE_DIRECTORY")
    }
    let modelURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let stateURL = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: stateURL.path) else {
      throw SmokeError.arguments(
        "State directory must be new; existing user data is never overwritten.")
    }
    let model = try LiteRTTextModel(id: "smoke.selected", modelURL: modelURL, sampling: .greedy)
    let backend = LiteRTProvider.localBackend(for: model)
    let outcome: Result<Void, any Error>
    do {
      let connector = try await backend.providerConnector(displayName: "Selected LiteRT model")
      let runtime = try await backend.load()
      let manager = AgentManager(
        dataStore: .directory(stateURL), providers: try ModelProviderRegistry([connector]))
      _ = try await manager.createAgent(
        id: "smoke", name: "Smoke",
        provider: .init(providerID: runtime.providerID, modelID: runtime.modelDescriptor.id))
      let native = try await manager.run(
        agentID: "smoke", input: "Say hello in one sentence.", sessionID: "native")
      guard native.status == .completed, let text = native.output else {
        throw SmokeError.agentDidNotComplete(String(describing: native.status))
      }
      print("NativeAgent:", text)
      guard await runtime.status().phase == .idle else { throw SmokeError.runtimeNotIdle }
      let appleModel = NativeAgentProviderAppleLocalAI.makeLanguageModel(
        runtime: runtime, sessionID: "apple")
      let apple = AppleLocalAISession(profile: try AppleLocalAIProfile(model: appleModel))
      let response = try await apple.respond(
        AppleLocalAIRequest(prompt: Prompt("Say hello in one sentence.")))
      print("AppleLocalAI:", response.content)
      let again = try await manager.run(
        agentID: "smoke", input: "Say goodbye in one sentence.", sessionID: "native-again")
      guard again.status == .completed, let textAgain = again.output else {
        throw SmokeError.agentDidNotComplete(String(describing: again.status))
      }
      guard try await backend.load() === runtime else { throw SmokeError.identityChanged }
      print("NativeAgent again:", textAgain)
      outcome = .success(())
    } catch { outcome = .failure(error) }
    do { try await backend.shutdown() } catch {
      switch outcome {
      case .success: throw error
      case .failure(let operation):
        throw SmokeError.operationAndCleanup(operation: operation, cleanup: error)
      }
    }
    try outcome.get()
    print(
      "Completed: one shared runtime across both frontends; host shutdown returned successfully.")
  }
}
private enum SmokeError: Error {
  case arguments(String)
  case agentDidNotComplete(String)
  case runtimeNotIdle, identityChanged
  case operationAndCleanup(operation: any Error, cleanup: any Error)
}
