import Foundation

/// Process-wide ownership for native model sessions.
///
/// Model-specific runtimes use this guard before loading native weights. It is
/// intentionally a single-owner gate: separate runtime wrappers cannot load
/// overlapping native sessions and silently double memory use.
public final class ProcessResidency: @unchecked Sendable {
  public static let shared = ProcessResidency()

  private let lock = NSLock()
  private var owner: UUID?
  private var poisoned = false
  private var poisonedObjects: [AnyObject] = []

  private init() {}

  public func claim() throws -> ProcessResidencyLease {
    try claim(UUID())
  }

  public func claim(_ candidate: UUID) throws -> ProcessResidencyLease {
    lock.lock()
    defer { lock.unlock() }
    guard !poisoned, owner == nil else { throw ProcessResidencyError.busy }
    owner = candidate
    return ProcessResidencyLease(owner: candidate, coordinator: self)
  }

  fileprivate func release(_ candidate: UUID) {
    lock.lock()
    defer { lock.unlock() }
    if owner == candidate { owner = nil }
  }

  fileprivate func poison(_ candidate: UUID, retaining objects: [AnyObject]) {
    lock.lock()
    defer { lock.unlock() }
    guard owner == candidate else { return }
    poisoned = true
    poisonedObjects = objects
  }

  public func isPoisoned() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return poisoned
  }
}

public enum ProcessResidencyError: Error, Equatable, Sendable {
  case busy
}

public final class ProcessResidencyLease: @unchecked Sendable {
  private let owner: UUID
  private let coordinator: ProcessResidency
  private let lock = NSLock()
  private var closed = false

  fileprivate init(owner: UUID, coordinator: ProcessResidency) {
    self.owner = owner
    self.coordinator = coordinator
  }

  public func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    coordinator.release(owner)
  }

  public func poison(retaining objects: [AnyObject]) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    coordinator.poison(owner, retaining: objects)
  }

  deinit { close() }
}
