import Foundation
import LanguageModelCore
import Testing

@testable import LanguageModelRuntime

@Suite("Explicit owned and borrowed runtime access")
struct ModelRuntimeAccessTests {
  @Test func existingConnectorsKeepOwnedCleanup() async throws {
    let runtime = try runtimeFixture()
    let connector = try legacyConnector(runtime)
    let registry = try ModelProviderRegistry([connector])
    let access = try await registry.acquireRuntime(selection())
    guard case .owned = access else {
      Issue.record("Ownership changed")
      return
    }
    #expect(access.runtime === runtime)
    try await access.release()
    try await access.release()
    #expect(await runtime.status().phase == .closed)
  }

  @Test func legacyRegistryMakeRuntimeStillTransfersOwnership() async throws {
    let runtime = try runtimeFixture()
    let registry = try ModelProviderRegistry([legacyConnector(runtime)])
    #expect(try await registry.makeRuntime(selection()) === runtime)
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func registryAndAppleBorrowTheSameHostRuntimeAcrossOperations() async throws {
    let runtime = try runtimeFixture()
    let backend = LocalBackend(load: { runtime }, releaseResident: {})
    let registry = try ModelProviderRegistry([
      try await backend.providerConnector(displayName: "Local")
    ])
    let first = try await registry.acquireRuntime(selection())
    guard case .borrowed = first else {
      Issue.record("Borrow became ownership")
      return
    }
    #expect(first.runtime === (try await backend.load()))
    try await first.release()
    #expect(await runtime.status().phase == .idle)
    let second = try await registry.acquireRuntime(selection())
    #expect(second.runtime === first.runtime)
    try await second.release()
    try await backend.shutdown()
    #expect(await runtime.status().phase == .closed)
  }

  @Test func borrowedRuntimeCannotAccidentallyUseOwnershipTransferAPI() async throws {
    let runtime = try runtimeFixture()
    let backend = LocalBackend(load: { runtime }, releaseResident: {})
    let connector = try await backend.providerConnector(displayName: "Local")
    let registry = try ModelProviderRegistry([connector])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await registry.makeRuntime(selection())
    }
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await connector.makeRuntime(modelID: nil)
    }
    #expect(await runtime.status().phase == .idle)
    try await backend.shutdown()
  }

  @Test func wrongBorrowedProviderIsRejectedWithoutClosingTheHost() async throws {
    let runtime = try runtimeFixture()
    let wrong = WrongIdentityConnector(access: .borrowed(runtime))
    let registry = try ModelProviderRegistry([wrong])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await registry.acquireRuntime(
        try ModelProviderSelection(providerID: wrong.descriptor.id))
    }
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func wrongOwnedProviderIsRejectedAndReleased() async throws {
    let runtime = try runtimeFixture()
    let wrong = WrongIdentityConnector(access: .owned(runtime))
    let registry = try ModelProviderRegistry([wrong])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await registry.acquireRuntime(
        try ModelProviderSelection(providerID: wrong.descriptor.id))
    }
    #expect(await runtime.status().phase == .closed)
  }

  @Test func closedBackendIsUnavailableRatherThanReloadedOrSubstituted() async throws {
    let runtime = try runtimeFixture()
    let backend = LocalBackend(load: { runtime }, releaseResident: {})
    let connector = try await backend.providerConnector(displayName: "Local")
    let registry = try ModelProviderRegistry([connector])
    try await backend.shutdown()
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await registry.acquireRuntime(selection())
    }
    #expect(await backend.status() == .closed)
  }

  @Test func differentModelIsRejectedWithoutAffectingTheSelectedModel() async throws {
    let runtime = try runtimeFixture()
    let backend = LocalBackend(load: { runtime }, releaseResident: {})
    let connector = try await backend.providerConnector(displayName: "Local")
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await connector.acquireRuntime(modelID: "other")
    }
    #expect(try await connector.acquireRuntime(modelID: nil).runtime === runtime)
    #expect(try await connector.models() == [runtime.modelDescriptor])
    try await backend.shutdown()
  }
}

private struct AccessFixture: ModelClient {
  let providerID = "test.access"
  var modelDescriptor: ModelDescriptor? {
    .init(id: "model", providerID: providerID, capabilities: .textOnly)
  }
  func generate(request: ModelRequest) async throws -> ModelTurn { ModelTurn(content: "fixture") }
}
private func runtimeFixture() throws -> ModelRuntime {
  try ModelRuntime(id: .init(rawValue: "test.runtime"), client: AccessFixture())
}
private func selection() throws -> ModelProviderSelection {
  try .init(providerID: "test.access", modelID: "model")
}
private func legacyConnector(_ runtime: ModelRuntime) throws -> ClosureModelProviderConnector {
  ClosureModelProviderConnector(
    descriptor: try .init(id: runtime.providerID, displayName: "Legacy", kind: .onDevice),
    availability: { .available }, models: { [runtime.modelDescriptor] },
    makeRuntime: { _ in runtime })
}
private struct WrongIdentityConnector: ModelProviderConnector {
  let access: ModelRuntimeAccess
  var descriptor: ModelProviderDescriptor {
    try! .init(id: "wrong.provider", displayName: "Wrong", kind: .onDevice)
  }
  func availability() async throws -> ModelProviderAvailability { .available }
  func models() async throws -> [ModelDescriptor] { [] }
  func makeRuntime(modelID: String?) async throws -> ModelRuntime { access.runtime }
  func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess { access }
}
