@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Security
import Testing


@Suite("ChatGPT credentials", .serialized)
struct ChatGPTCredentialsTests {
  @Test func loadUsesCanonicalCredentials() throws {
    let current = tokenSet(suffix: "current")
    let operations = RecordingKeychainOperations(
      loadResults: [.found(try encoded(current))])
    let store = try ChatGPTKeychainStore(
      namespace: "com.example.nativeagent", operations: operations)

    #expect(try store.load() == current)
    #expect(operations.events.map(\.kind) == [.load])
  }

  @Test func saveWritesCanonicalItem() throws {
    let operations = RecordingKeychainOperations(
      updateResults: [errSecItemNotFound],
      addResults: [errSecSuccess])
    let store = try ChatGPTKeychainStore(
      namespace: "com.example.nativeagent", operations: operations)

    try store.save(tokenSet(suffix: "new"))

    #expect(operations.events.map(\.kind) == [.update, .add])
    #expect(operations.events[0].accessibility == .afterFirstUnlock)
    #expect(operations.events[1].accessibility == .afterFirstUnlock)
  }

  @Test func saveRetriesUpdateWhenAddLosesTheCreationRace() throws {
    let operations = RecordingKeychainOperations(
      updateResults: [errSecItemNotFound, errSecSuccess],
      addResults: [errSecDuplicateItem])
    let store = try ChatGPTKeychainStore(
      namespace: "com.example.nativeagent", operations: operations)

    try store.save(tokenSet(suffix: "race"))

    #expect(operations.events.map(\.kind) == [.update, .add, .update])
    #expect(operations.events[0].accessibility == .afterFirstUnlock)
    #expect(operations.events[2].accessibility == .afterFirstUnlock)
  }

  @Test func saveUpdateFailureDoesNotAttemptDelete() throws {
    let operations = RecordingKeychainOperations(
      updateResults: [errSecInteractionNotAllowed])
    let store = try ChatGPTKeychainStore(
      namespace: "com.example.nativeagent", operations: operations)

    #expect(throws: ChatGPTFailure.self) {
      try store.save(tokenSet(suffix: "update-failure"))
    }
    #expect(operations.events.map(\.kind) == [.update])
    #expect(!operations.events.contains { $0.kind == .delete })
  }

  @Test func saveAddFailureDoesNotAttemptDelete() throws {
    let operations = RecordingKeychainOperations(
      updateResults: [errSecItemNotFound],
      addResults: [errSecInteractionNotAllowed])
    let store = try ChatGPTKeychainStore(
      namespace: "com.example.nativeagent", operations: operations)

    #expect(throws: ChatGPTFailure.self) {
      try store.save(tokenSet(suffix: "add-failure"))
    }
    #expect(operations.events.map(\.kind) == [.update, .add])
    #expect(!operations.events.contains { $0.kind == .delete })
  }

  @Test func deleteReportsCanonicalFailure() throws {
    let operations = RecordingKeychainOperations(
      deleteResults: [errSecInteractionNotAllowed])
    let store = try ChatGPTKeychainStore(
      namespace: "com.example.nativeagent", operations: operations)

    #expect(throws: ChatGPTFailure.self) {
      try store.delete()
    }
    #expect(operations.events.map(\.kind) == [.delete])
  }

  private func encoded(_ value: ChatGPTTokenSet) throws -> Data {
    try JSONEncoder().encode(value)
  }
}

private final class RecordingKeychainOperations: @unchecked Sendable,
  ChatGPTKeychainOperations
{
  struct Event: Equatable {
    enum Kind: Equatable {
      case load
      case update
      case add
      case delete
    }

    let kind: Kind
    let accessibility: ChatGPTKeychainAccessibility?
  }

  var loadResults: [ChatGPTKeychainLookup]
  var updateResults: [Int32]
  var addResults: [Int32]
  var deleteResults: [Int32]
  private var storedData: Data?
  private(set) var events: [Event] = []

  init(
    loadResults: [ChatGPTKeychainLookup] = [],
    updateResults: [Int32] = [],
    addResults: [Int32] = [],
    deleteResults: [Int32] = []
  ) {
    self.loadResults = loadResults
    self.updateResults = updateResults
    self.addResults = addResults
    self.deleteResults = deleteResults
  }

  func load(service: String, account: String) -> ChatGPTKeychainLookup {
    events.append(Event(kind: .load, accessibility: nil))
    if !loadResults.isEmpty { return loadResults.removeFirst() }
    return storedData.map(ChatGPTKeychainLookup.found) ?? .notFound
  }

  func update(
    service: String,
    account: String,
    data: Data,
    accessibility: ChatGPTKeychainAccessibility
  ) -> Int32 {
    events.append(Event(kind: .update, accessibility: accessibility))
    let status = updateResults.isEmpty ? errSecItemNotFound : updateResults.removeFirst()
    if status == errSecSuccess { storedData = data }
    return status
  }

  func add(
    service: String,
    account: String,
    data: Data,
    accessibility: ChatGPTKeychainAccessibility
  ) -> Int32 {
    events.append(Event(kind: .add, accessibility: accessibility))
    let status = addResults.isEmpty ? errSecSuccess : addResults.removeFirst()
    if status == errSecSuccess { storedData = data }
    return status
  }

  func delete(service: String, account: String) -> Int32 {
    events.append(Event(kind: .delete, accessibility: nil))
    let status = deleteResults.isEmpty ? errSecItemNotFound : deleteResults.removeFirst()
    if status == errSecSuccess { storedData = nil }
    return status
  }
}

private func tokenSet(suffix: String) -> ChatGPTTokenSet {
  ChatGPTTokenSet(
    accessToken: "access-\(suffix)",
    refreshToken: "refresh-\(suffix)",
    idToken: "id-\(suffix)",
    expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
    account: ChatGPTAccount(
      accountID: "account-\(suffix)", plan: "plus", email: "\(suffix)@example.com")
  )
}
