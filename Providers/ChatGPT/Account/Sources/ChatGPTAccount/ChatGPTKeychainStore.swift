#if canImport(Security)
import Foundation
import Security

enum ChatGPTKeychainAccessibility: Sendable, Equatable {
  case afterFirstUnlock
}

enum ChatGPTKeychainLookup: Sendable {
  case found(Data)
  case notFound
  case failure(Int32)
}

protocol ChatGPTKeychainOperations: Sendable {
  func load(service: String, account: String) -> ChatGPTKeychainLookup
  func update(
    service: String,
    account: String,
    data: Data,
    accessibility: ChatGPTKeychainAccessibility
  ) -> Int32
  func add(
    service: String,
    account: String,
    data: Data,
    accessibility: ChatGPTKeychainAccessibility
  ) -> Int32
  func delete(service: String, account: String) -> Int32
}

private struct ChatGPTLiveKeychainOperations: ChatGPTKeychainOperations {
  func load(service: String, account: String) -> ChatGPTKeychainLookup {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return .notFound }
    guard status == errSecSuccess, let data = item as? Data else {
      return .failure(status)
    }
    return .found(data)
  }

  func update(
    service: String,
    account: String,
    data: Data,
    accessibility: ChatGPTKeychainAccessibility
  ) -> Int32 {
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: accessibleValue(accessibility),
    ]
    return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func add(
    service: String,
    account: String,
    data: Data,
    accessibility: ChatGPTKeychainAccessibility
  ) -> Int32 {
    var item = baseQuery(service: service, account: account)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = accessibleValue(accessibility)
    return SecItemAdd(item as CFDictionary, nil)
  }

  func delete(service: String, account: String) -> Int32 {
    SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
  }

  private func baseQuery(
    service: String,
    account: String
  ) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: true,
    ]
  }

  private func accessibleValue(_ accessibility: ChatGPTKeychainAccessibility) -> CFString {
    switch accessibility {
    case .afterFirstUnlock:
      kSecAttrAccessibleAfterFirstUnlock
    }
  }
}

struct ChatGPTKeychainStore: ChatGPTCredentialStoring, Sendable {
  private let service: String
  private let account = "chatgpt-subscription"
  private let operations: any ChatGPTKeychainOperations

  init(namespace: String) throws {
    try self.init(namespace: namespace, operations: ChatGPTLiveKeychainOperations())
  }

  init(namespace: String, operations: any ChatGPTKeychainOperations) throws {
    guard (1...ChatGPTCredentialLimits.maximumCredentialNamespaceUTF8Bytes).contains(namespace.utf8.count),
      namespace.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F })
    else { throw ChatGPTFailure(.invalidConfiguration) }
    service = "\(namespace).ChatGPT"
    self.operations = operations
  }

  func load() throws -> ChatGPTTokenSet? {
    switch operations.load(service: service, account: account) {
    case .found(let data):
      return try decode(data)
    case .failure:
      throw ChatGPTFailure(.credentialStorageFailed)
    case .notFound:
      return nil
    }
  }

  func save(_ value: ChatGPTTokenSet) throws {
    try value.validate()
    let data: Data
    do { data = try JSONEncoder().encode(value) } catch {
      throw ChatGPTFailure(.credentialStorageFailed)
    }

    try saveSynchronizable(data)
  }

  func delete() throws {
    let status = operations.delete(service: service, account: account)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ChatGPTFailure(.credentialStorageFailed)
    }
  }

  private func decode(_ data: Data) throws -> ChatGPTTokenSet {
    do {
      let value = try JSONDecoder().decode(ChatGPTTokenSet.self, from: data)
      try value.validate()
      return value
    } catch let failure as ChatGPTFailure {
      throw failure
    } catch {
      throw ChatGPTFailure(.credentialStorageFailed)
    }
  }

  private func saveSynchronizable(_ data: Data) throws {
    let update = operations.update(
      service: service,
      account: account,
      data: data,
      accessibility: .afterFirstUnlock
    )
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw ChatGPTFailure(.credentialStorageFailed)
    }

    let add = operations.add(
      service: service,
      account: account,
      data: data,
      accessibility: .afterFirstUnlock
    )
    if add == errSecSuccess { return }
    guard add == errSecDuplicateItem else {
      throw ChatGPTFailure(.credentialStorageFailed)
    }

    let retry = operations.update(
      service: service,
      account: account,
      data: data,
      accessibility: .afterFirstUnlock
    )
    guard retry == errSecSuccess else {
      throw ChatGPTFailure(.credentialStorageFailed)
    }
  }

}

#endif
