import Darwin
import Foundation
import NativeAgent
import NativeAgentManager
import AppleSystemModelProvider

enum QualificationFailure: Error { case invalidArguments, expectation(String) }

actor StreamWitness: RuntimeObserver {
  let stopMarker: URL?
  var deltas = 0
  var starts = 0
  init(stopMarker: URL?) { self.stopMarker = stopMarker }
  func record(modelStream event: ModelInvocationStreamEvent) async {
    if case .started = event.event { starts += 1 }
    guard case .textDelta = event.event else { return }
    deltas += 1
    if let stopMarker, deltas == 1 {
      do {
        try Data("first real model delta; session=\(event.sessionID)".utf8)
          .write(to: stopMarker, options: .atomic)
        raise(SIGSTOP) // Harness only: parent owns the exact child handle and kills/reaps it.
      } catch { _exit(91) }
    }
  }
  func record(effectDecision event: ToolEffectDecisionEvent) async {}
  func record(toolExecutionDuration event: ToolExecutionDurationEvent) async {}
}

@main
struct DurableLiveQualification {
  static func main() async throws {
    guard CommandLine.arguments.count == 3,
          ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_FOUNDATION"] == "1" else {
      throw QualificationFailure.invalidArguments
    }
    let mode = CommandLine.arguments[1]
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let witness = StreamWitness(stopMarker: mode == "interrupt" ? root.appendingPathComponent("delta-ready") : nil)
    let connector = try FoundationModelsProviderConnector()
    let manager = AgentManager(dataStore: .directory(root), providers: try .init([connector]), observer: witness)
    let expectedURL = root.appendingPathComponent("expected.json")
    if mode == "create" {
      _ = try await manager.createAgent(id: "qualification", name: "Qualification",
        provider: .init(providerID: connector.descriptor.id))
      let first = try await manager.run(agentID: "qualification", input: "What is two plus two? Answer in one short sentence.", sessionID: "durable-live")
      guard first.status == .completed, let output = first.output, !output.isEmpty else {
        throw QualificationFailure.expectation("first real managed generation incomplete")
      }
      try JSONEncoder.nativeAgent().encode(first.snapshot).write(to: expectedURL, options: .atomic)
      print("MANAGER_REAL_GENERATION completed session=\(first.sessionID) output=\(output)")
    } else if mode == "interrupt" {
      _ = try await manager.send(agentID: "qualification", input: "Describe ten different animals and their habitats in separate sentences.", to: "durable-live")
      throw QualificationFailure.expectation("interruption boundary was not reached")
    } else if mode == "reopen" {
      let expected = try JSONDecoder.nativeAgent().decode(SessionSnapshot.self, from: Data(contentsOf: expectedURL))
      let reopened = try await manager.session(agentID: "qualification", id: "durable-live")
      guard prefixMatches(reopened.messages, expected.messages), reopened.status == .running else {
        throw QualificationFailure.expectation("durable prefix or interrupted running state lost")
      }
      // SIGKILL cannot persist the normal failure transition. Resuming a running
      // session first observes its started receipt and enters a reconciliation wait.
      let waiting = try await manager.resume(agentID: "qualification", sessionID: "durable-live")
      let interruptedData = try Data(contentsOf: root.appendingPathComponent("interrupted-readback.json"))
      let interrupted = try JSONDecoder().decode(InterruptedEvidence.self, from: interruptedData)
      guard waiting.status == .waiting, waiting.snapshot.waitState?.kind == .modelInvocation,
            await witness.deltas == 0, await witness.starts == 0,
            let pending = try await manager.pendingModelInvocation(agentID: "qualification", sessionID: "durable-live"),
            pending.id == interrupted.invocationID else {
        throw QualificationFailure.expectation("unknown invocation did not enter reconciliation without replay")
      }
      print("UNKNOWN_INVOCATION_RESUME waiting=observed startedReceiptIdentity=preserved providerStartEvents=0 providerDeltas=0")
      let retried = try await manager.resolveModelInvocation(agentID: "qualification", sessionID: "durable-live",
        invocationID: pending.id, resolution: .retry(reason: "Explicit local qualification retry after owned process death"))
      guard retried.status == .completed, !(retried.output ?? "").isEmpty,
            prefixMatches(retried.messages, expected.messages) else {
        throw QualificationFailure.expectation("explicit retry did not preserve durable history")
      }
      try JSONEncoder.nativeAgent().encode(retried.snapshot).write(to: root.appendingPathComponent("reopened.json"), options: .atomic)
      print("MANAGER_FRESH_PROCESS prefix=preserved pending=observed blindReplay=blocked explicitRetry=completed")
    } else { throw QualificationFailure.invalidArguments }
  }

  struct InterruptedEvidence: Decodable { let invocationID: String }

  static func prefixMatches(_ actual: [AgentMessage], _ expected: [AgentMessage]) -> Bool {
    guard actual.count >= expected.count else { return false }
    return Array(actual.prefix(expected.count)) == expected
  }
}
