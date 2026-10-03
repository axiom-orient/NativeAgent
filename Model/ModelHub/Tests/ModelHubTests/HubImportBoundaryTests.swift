import LanguageModelCore
import ModelHub
import Testing

@Suite("Hub import effect boundaries")
struct HubImportBoundaryTests {
  @Test func installationCannotReturnADifferentProvider() async throws {
    let backend = BoundaryBackend(result: .init(id: "model", providerID: "other.provider"))
    let installer = try HubModelInstaller(backends: [backend])
    await #expect(throws: HubModelImportError.invalidCandidate) {
      _ = try await installer.install(backend.candidate())
    }
  }

  @Test func installationValidatesTheReturnedDescriptor() async throws {
    let backend = BoundaryBackend(result: .init(id: "", providerID: "test.provider"))
    let installer = try HubModelInstaller(backends: [backend])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await installer.install(backend.candidate())
    }
  }

  @Test func cancelledDiscoveryNeverStartsInstallation() async throws {
    let gate = ImportGate()
    let probe = ImportProbe()
    let backend = BoundaryBackend(inspectGate: gate, probe: probe)
    let installer = try HubModelInstaller(backends: [backend])
    let task = Task { try await installer.install(from: "acme/model") }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    await expectCancellation(task)
    #expect(await probe.installs == 0)
  }

  @Test func cancelledCallerDoesNotDispatchAnExplicitInstall() async throws {
    let gate = ImportGate()
    let probe = ImportProbe()
    let backend = BoundaryBackend(probe: probe)
    let installer = try HubModelInstaller(backends: [backend])
    let candidate = try backend.candidate()
    let task = Task {
      await gate.pause()
      return try await installer.install(candidate)
    }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    await expectCancellation(task)
    #expect(await probe.installs == 0)
  }

  @Test func observedInstalledResultIsNotDiscardedAfterCancellation() async throws {
    let gate = ImportGate()
    let backend = BoundaryBackend(installGate: gate)
    let installer = try HubModelInstaller(backends: [backend])
    let task = Task { try await installer.install(backend.candidate()) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    // The backend already crossed its write boundary. Preserve its observed receipt;
    // cancellation can stop a subsequent load but must not pretend the install vanished.
    #expect(try await task.value == backend.result)
  }
}

private struct BoundaryBackend: HubModelImportBackend {
  let hubBackendID = "test.backend"
  let hubProviderID = "test.provider"
  var result = ModelDescriptor(id: "model", providerID: "test.provider")
  var inspectGate: ImportGate?
  var installGate: ImportGate?
  var probe: ImportProbe?
  func candidate() throws -> HubModelImportCandidate {
    try .init(
      backendID: hubBackendID, providerID: hubProviderID,
      repositoryID: "acme/model", revision: String(repeating: "a", count: 40),
      displayName: "Fixture", artifactPaths: ["model.bin"], totalBytes: 128)
  }
  func inspectModel(at address: HubModelAddress) async throws -> HubModelImportCandidate? {
    await inspectGate?.pause()
    return try candidate()
  }
  func installModel(
    _ candidate: HubModelImportCandidate,
    progress: (@Sendable (HubModelDownloadProgress) -> Void)?
  ) async throws -> ModelDescriptor {
    await probe?.install()
    await installGate?.pause()
    return result
  }
}
private actor ImportProbe {
  var installs = 0
  func install() { installs += 1 }
}
private actor ImportGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  func pause() async {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func open() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}
private func expectCancellation(_ task: Task<ModelDescriptor, any Error>) async {
  do {
    _ = try await task.value
    Issue.record("Cancelled import returned success")
  } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}
