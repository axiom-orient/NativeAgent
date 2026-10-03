import Foundation

/// Thread-safe completion/quarantine cell. Native resource ownership stays with the runtime.
final class LeapResultHandle<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var resultValue: Result<Value, any Error>?
  private var quarantined = false
  private var cleanupFailed = false

  @discardableResult
  func finish(_ result: Result<Value, any Error>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard resultValue == nil else { return false }
    if quarantined {
      resultValue = .failure(CancellationError())
      return true
    }
    resultValue = result
    return false
  }

  func result() -> Result<Value, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    return resultValue
  }

  func quarantine() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard resultValue == nil else { return false }
    quarantined = true
    return true
  }

  func markCleanupFailure() {
    lock.lock()
    cleanupFailed = true
    lock.unlock()
  }

  func didCleanupFail() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cleanupFailed
  }
}
