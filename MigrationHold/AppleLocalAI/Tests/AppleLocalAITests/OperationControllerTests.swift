import Testing
@testable import AppleLocalAI

private enum EffectFailure: Error { case expected }

/// Deterministic non-cooperative effect: cancellation cannot release it.
private actor EffectGate {
  private var entered = false
  private var enterWaiters: [CheckedContinuation<Void, Never>] = []
  private var result: CheckedContinuation<Int, Never>?

  func run() async -> Int {
    entered = true
    enterWaiters.forEach { $0.resume() }
    enterWaiters.removeAll()
    return await withCheckedContinuation { result = $0 }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enterWaiters.append($0) }
  }
  func release() {
    result?.resume(returning: 7)
    result = nil
  }
}

@Suite("Native operation ownership")
@MainActor
struct OperationControllerTests {
  @Test func successSettlesExactlyOnce() async throws {
    let controller = OperationController()
    let result = try await controller.perform { 7 }
    #expect(result == 7)
    #expect(!controller.isBusy)
  }

  @Test func originalFailureIsNotHidden() async {
    let controller = OperationController()
    do {
      _ = try await controller.perform { () -> Int in throw EffectFailure.expected }
      Issue.record("Expected the original failure")
    } catch EffectFailure.expected {} catch { Issue.record("Wrong failure: \(error)") }
    #expect(!controller.isBusy)
  }

  @Test func explicitCancellationDrainsBeforeReuseAndRejectsLateSuccess() async throws {
    let controller = OperationController()
    let gate = EffectGate()
    let running = Task { try await controller.perform { await gate.run() } }
    await gate.waitUntilEntered()
    controller.cancel()
    controller.cancel() // Idempotent; no second transition or settlement.
    #expect(controller.isBusy)
    var replacementStarted = false
    do {
      _ = try await controller.perform { replacementStarted = true; return 9 }
      Issue.record("A draining operation admitted a replacement")
    } catch {}
    #expect(!replacementStarted)
    await gate.release()
    do { _ = try await running.value; Issue.record("Late success escaped cancellation") }
    catch is CancellationError {} catch { Issue.record("Wrong failure: \(error)") }
    #expect(!controller.isBusy)
    #expect(try await controller.perform { 11 } == 11)
  }

  @Test func parentCancellationRejectsNonCooperativeLateSuccess() async {
    let controller = OperationController()
    let gate = EffectGate()
    let running = Task { try await controller.perform { await gate.run() } }
    await gate.waitUntilEntered()
    running.cancel()
    #expect(controller.isBusy)
    await gate.release()
    do { _ = try await running.value; Issue.record("Parent cancellation was lost") }
    catch is CancellationError {} catch { Issue.record("Wrong failure: \(error)") }
    #expect(!controller.isBusy)
  }

  @Test func alreadyCancelledCallerCannotStartEffect() async {
    let controller = OperationController()
    var didStart = false
    // MainActor keeps this task from starting until the current turn yields.
    let task = Task { try await controller.perform { didStart = true; return 1 } }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled caller succeeded") }
    catch is CancellationError {} catch { Issue.record("Wrong failure: \(error)") }
    #expect(!didStart)
    #expect(!controller.isBusy)
  }

  @Test func cancelWhenIdleDoesNotPoisonTheNextOperation() async throws {
    let controller = OperationController()
    controller.cancel()
    #expect(try await controller.perform { 3 } == 3)
  }
}
