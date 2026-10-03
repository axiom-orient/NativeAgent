import Foundation

/// Thread-safe completion/quarantine cell. Native resource ownership stays with the runtime.
final class MLXResultHandle<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<Value, any Error>?
  private var quarantined = false

  @discardableResult
  func finish(_ result: Result<Value, any Error>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard value == nil else { return false }
    if quarantined {
      value = .failure(CancellationError())
      return true
    }
    value = result
    return false
  }

  func result() -> Result<Value, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func quarantine() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard value == nil else { return false }
    quarantined = true
    return true
  }
}
