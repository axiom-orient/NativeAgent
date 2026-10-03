import Foundation
import NativeAgentDomain
import NativeAgentStore
import NativeAgentTestSupport
import Testing

@testable import NativeAgentExecution

/// Holds admitted operations until every contender has reached admission or rejection.
/// No sleeps or real model calls are used to manufacture a timing-dependent outcome.
private actor SessionAdmissionProbe {
  private let expected: Int
  private var admitted = 0
  private var rejected = 0
  private var allAttempted: CheckedContinuation<Void, Never>?
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  init(expected: Int) { self.expected = expected }

  func enterAndWait() async {
    admitted += 1
    signalAllAttempted()
    await withCheckedContinuation { operationWaiters.append($0) }
  }

  func reject() {
    rejected += 1
    signalAllAttempted()
  }

  func waitUntilAllAttempted() async {
    guard admitted + rejected < expected else { return }
    await withCheckedContinuation { allAttempted = $0 }
  }

  func release() -> (admitted: Int, rejected: Int) {
    for waiter in operationWaiters { waiter.resume() }
    operationWaiters.removeAll()
    return (admitted, rejected)
  }

  private func signalAllAttempted() {
    guard admitted + rejected == expected else { return }
    allAttempted?.resume()
    allAttempted = nil
  }
}

/// Occupies the real recovery actor so the coordinator must suspend at its actor hop.
/// This is test scheduling control, not a replacement recovery-store implementation.
private final class RecoveryActorOccupancy: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var released = false

  func occupy() {
    condition.lock()
    started = true
    while !released { condition.wait() }
    condition.unlock()
  }

  func hasStarted() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return started
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

extension SessionExecutionAuthority {
  fileprivate func occupyForAdmissionRegression(_ occupancy: RecoveryActorOccupancy) {
    occupancy.occupy()
  }
}

@Test(.timeLimit(.minutes(1)))
func coordinatorOnlyAdmissionReservesBeforeCrossActorAwait() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("session-admission-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: ApplicationSupportSessionStore(rootURL: root),
    toolPacks: [],
    configuration: RuntimeConfiguration(
      safetyPolicy: RuntimeSafetyPolicy(sessionExecution: .coordinatorOnly)
    )
  )
  let occupancy = RecoveryActorOccupancy()
  let recoveryStore = await coordinator.executionAuthority
  let occupiedActor = Task.detached {
    await recoveryStore.occupyForAdmissionRegression(occupancy)
  }
  while !occupancy.hasStarted() { await Task.yield() }
  defer { occupancy.release() }
  let contenders = 128
  let probe = SessionAdmissionProbe(expected: contenders)
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<contenders {
      group.addTask {
        do {
          try await coordinator.withSessionExecution(sessionID: "one-session") {
            await probe.enterAndWait()
          }
        } catch {
          if case AgentError.sessionBusy("one-session") = error {
            // This is the expected rejection, not a provider or persistence error.
          } else {
            Issue.record("Unexpected admission error: \(error)")
          }
          await probe.reject()
        }
      }
    }
    // Let contenders queue while the recovery actor is occupied. The passing
    // invariant does not depend on how many contenders the scheduler starts here.
    for _ in 0..<256 { await Task.yield() }
    occupancy.release()
    await occupiedActor.value
    await probe.waitUntilAllAttempted()
    let observed = await probe.release()
    #expect(observed.admitted == 1)
    #expect(observed.rejected == contenders - 1)
  }
  // The reservation must also be released after the successful operation.
  let value = try await coordinator.withSessionExecution(sessionID: "one-session") { 42 }
  #expect(value == 42)
}

private struct SessionAdmissionFailure: Error {}

@Test
func coordinatorAdmissionReleasesReservationAfterOperationFailure() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("session-admission-error-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let coordinator = try SessionCoordinator(
    modelClient: ScriptedModelClient(),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: ApplicationSupportSessionStore(rootURL: root),
    toolPacks: [],
    configuration: RuntimeConfiguration(
      safetyPolicy: RuntimeSafetyPolicy(sessionExecution: .coordinatorOnly)
    )
  )
  do {
    try await coordinator.withSessionExecution(sessionID: "failed-session") {
      throw SessionAdmissionFailure()
    }
    Issue.record("Expected operation failure.")
  } catch is SessionAdmissionFailure {
    // The original failure must remain observable.
  }
  let value = try await coordinator.withSessionExecution(sessionID: "failed-session") { 7 }
  #expect(value == 7)
}
