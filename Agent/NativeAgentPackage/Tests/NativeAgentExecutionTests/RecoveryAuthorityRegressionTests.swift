import Foundation
import NativeAgentDomain
import NativeAgentStore
import NativeAgentTestSupport
import Testing
@testable import NativeAgentExecution

private actor RecoveryExecutionLatch {
  private var entered = false
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func hold() async {
    entered = true
    enteredWaiter?.resume()
    enteredWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }

  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

@Test(.timeLimit(.minutes(1)))
func recoveryCannotBypassActiveCoordinatorOnlyExecution() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("recovery-authority-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  let authority = SessionExecutionAuthority()
  let configuration = RuntimeConfiguration(
    safetyPolicy: RuntimeSafetyPolicy(sessionExecution: .coordinatorOnly)
  )
  let coordinator = try SessionCoordinator(
    modelRuntime: makeTestModelRuntime(ScriptedModelClient()),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    executionAuthority: authority,
    toolPacks: [],
    configuration: configuration
  )
  let reader = try SessionRecoveryReader(
    runtimeStore: store,
    executionClaimStore: nil,
    executionAuthority: authority,
    toolPacks: [],
    configuration: configuration
  )
  let latch = RecoveryExecutionLatch()
  let operation = Task {
    try await coordinator.withSessionExecution(sessionID: "active-session") {
      await latch.hold()
    }
  }
  await latch.waitUntilEntered()
  do {
    _ = try await reader.resolveToolEffect(
      sessionID: "active-session", callID: "tool", resolution: .failed("host resolution")
    )
    Issue.record("Recovery bypassed active execution.")
  } catch {
    guard case AgentError.sessionBusy("active-session") = error else {
      Issue.record("Expected shared admission rejection before I/O, received \(error).")
      await latch.release()
      _ = await operation.result
      return
    }
  }
  await latch.release()
  try await operation.value
}

@Test
func recoveryRejectsInvalidRuntimeConfiguration() throws {
  let store = ApplicationSupportSessionStore(
    rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  )
  #expect(throws: AgentError.self) {
    try SessionRecoveryReader(
      runtimeStore: store,
      executionClaimStore: nil,
      executionAuthority: SessionExecutionAuthority(),
      toolPacks: [],
      configuration: RuntimeConfiguration(maxIterations: 0)
    )
  }
}

// Fault-injection at the claim boundary proves admission/retry ordering, not a
// provider's native resource behavior. The latch makes the interleaving explicit.
private actor RetryClaimProbe: SessionExecutionClaimStore {
  private let latch: RecoveryExecutionLatch
  private var claim: SessionExecutionClaim?
  private(set) var releaseAttempts = 0

  init(latch: RecoveryExecutionLatch) { self.latch = latch }

  func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
    guard claim == nil else { throw AgentError.sessionBusy(sessionID) }
    let value = SessionExecutionClaim(sessionID: sessionID, claimID: UUID().uuidString)
    claim = value
    return value
  }

  func releaseExecutionClaim(_ value: SessionExecutionClaim) async throws {
    releaseAttempts += 1
    guard value.claimID == claim?.claimID else {
      throw AgentError.persistenceFailure("Attempt to release an unowned claim.")
    }
    if releaseAttempts == 1 {
      throw AgentError.persistenceFailure("Injected release failure.")
    }
    if releaseAttempts == 2 { await latch.hold() }
    claim = nil
  }
}

@Test(.timeLimit(.minutes(1)))
func recoveryAndCoordinatorCannotRetryTheSameClaimConcurrently() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let latch = RecoveryExecutionLatch()
  let claims = RetryClaimProbe(latch: latch)
  let store = ApplicationSupportSessionStore(rootURL: root, executionClaimStore: claims)
  let authority = SessionExecutionAuthority()
  let coordinator = try SessionCoordinator(
    modelRuntime: makeTestModelRuntime(ScriptedModelClient()),
    approvalRouter: AllowAllApprovalRouter(),
    runtimeStore: store,
    executionAuthority: authority,
    toolPacks: []
  )
  let reader = try SessionRecoveryReader(
    runtimeStore: store, executionClaimStore: claims,
    executionAuthority: authority, toolPacks: [], configuration: RuntimeConfiguration()
  )
  await #expect(throws: AgentError.self) {
    try await coordinator.withSessionExecution(sessionID: "retry-session") { () }
  }
  let retry = Task {
    try await coordinator.retryPendingExecutionClaimRelease(sessionID: "retry-session")
  }
  await latch.waitUntilEntered()
  do {
    _ = try await reader.retryPendingExecutionClaimRelease(sessionID: "retry-session")
    Issue.record("Concurrent recovery released the same claim twice.")
  } catch {
    #expect((error as? AgentError) == .sessionBusy("retry-session"))
  }
  #expect(await claims.releaseAttempts == 2)
  await latch.release()
  #expect(try await retry.value)
  #expect(try await reader.retryPendingExecutionClaimRelease(sessionID: "retry-session") == false)
  try await coordinator.withSessionExecution(sessionID: "retry-session") { () }
}

private actor DelayedAcquisitionProbe: SessionExecutionClaimStore {
  let latch: RecoveryExecutionLatch
  private(set) var released = false
  init(latch: RecoveryExecutionLatch) { self.latch = latch }
  func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
    await latch.hold()
    return SessionExecutionClaim(sessionID: sessionID, claimID: "delayed-claim")
  }
  func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws { released = true }
}

@Test(.timeLimit(.minutes(1)))
func cancellationDuringClaimAcquisitionReleasesClaimWithoutRunningOperation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let latch = RecoveryExecutionLatch()
  let claims = DelayedAcquisitionProbe(latch: latch)
  let store = ApplicationSupportSessionStore(rootURL: root, executionClaimStore: claims)
  let coordinator = try SessionCoordinator(
    modelRuntime: makeTestModelRuntime(ScriptedModelClient()),
    approvalRouter: AllowAllApprovalRouter(), runtimeStore: store, toolPacks: []
  )
  let operation = Task {
    try await coordinator.withSessionExecution(sessionID: "cancel-session") {
      Issue.record("Cancelled admission entered the operation.")
      return ()
    }
  }
  await latch.waitUntilEntered()
  operation.cancel()
  await latch.release()
  do {
    try await operation.value
    Issue.record("Cancelled admission returned success.")
  } catch is CancellationError {
    // Cancellation remains cancellation; the acquired claim is still released.
  }
  #expect(await claims.released)
  #expect(try await coordinator.retryPendingExecutionClaimRelease(sessionID: "cancel-session") == false)
}
