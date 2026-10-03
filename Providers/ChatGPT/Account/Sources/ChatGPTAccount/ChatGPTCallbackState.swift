import Foundation

/// The single owner of callback resource admission and completion facts.
/// No I/O, clocks or generated identities. The Network adapter supplies effects and receipts.
struct ChatGPTCallbackState<Connection: AnyObject & Sendable>: Sendable {
  enum Phase: Equatable, Sendable {
    case created, starting, running, stoppingListener, drainingConnections, stopped
  }
  private enum ConnectionPhase: Sendable { case receiving, responding, cancelling, cancelled }
  private struct Entry: Sendable {
    let connection: Connection
    var phase: ConnectionPhase = .receiving
    var pendingIO: UUID?
  }

  private(set) var phase: Phase = .created
  private var entries: [ObjectIdentifier: Entry] = [:]
  var connectionCount: Int { entries.count }
  var isDrained: Bool { phase == .stopped }

  mutating func start() -> Bool {
    guard phase == .created else { return false }
    phase = .starting
    return true
  }

  mutating func ready() -> Bool {
    guard phase == .starting else { return false }
    phase = .running
    return true
  }

  /// Even connections rejected during shutdown must be retained until their native receipts.
  mutating func track(_ connection: Connection) -> Bool {
    let id = ObjectIdentifier(connection)
    guard phase == .starting || phase == .running || phase == .stoppingListener,
      entries[id] == nil
    else { return false }
    entries[id] = Entry(connection: connection)
    return true
  }

  mutating func beginIO(on connection: Connection, id: UUID, response: Bool = false) -> Bool {
    let key = ObjectIdentifier(connection)
    guard phase == .running, var entry = entries[key], entry.phase == .receiving,
      entry.pendingIO == nil
    else { return false }
    if response { entry.phase = .responding }
    entry.pendingIO = id
    entries[key] = entry
    return true
  }

  /// An old or duplicate I/O callback cannot settle a newer operation on the same connection.
  mutating func completeIO(on connection: Connection, id: UUID) -> Bool {
    let key = ObjectIdentifier(connection)
    guard var entry = entries[key], entry.pendingIO == id else { return false }
    entry.pendingIO = nil
    entries[key] = entry
    releaseIfSettled(key)
    return true
  }

  mutating func cancel(_ connection: Connection) -> Connection? {
    let key = ObjectIdentifier(connection)
    guard var entry = entries[key], entry.phase != .cancelling, entry.phase != .cancelled else { return nil }
    entry.phase = .cancelling
    entries[key] = entry
    return connection
  }

  mutating func cancelConnections(preserving response: Connection? = nil) -> [Connection] {
    let preservedID = response.map(ObjectIdentifier.init)
    return Array(entries.values).compactMap { entry in
      guard ObjectIdentifier(entry.connection) != preservedID else { return nil }
      return cancel(entry.connection)
    }
  }

  /// Returns whether the adapter must issue listener.cancel(). An unused listener has no native work.
  mutating func stopListener() -> Bool {
    switch phase {
    case .created: phase = .stopped; return false
    case .starting, .running: phase = .stoppingListener; return true
    case .stoppingListener, .drainingConnections, .stopped: return false
    }
  }

  mutating func listenerCancelled() {
    guard phase == .stoppingListener else { return }
    phase = entries.isEmpty ? .stopped : .drainingConnections
  }

  mutating func connectionCancelled(_ connection: Connection) {
    let key = ObjectIdentifier(connection)
    guard var entry = entries[key] else { return }
    entry.phase = .cancelled
    entries[key] = entry
    releaseIfSettled(key)
  }

  private mutating func releaseIfSettled(_ key: ObjectIdentifier) {
    guard let entry = entries[key], entry.phase == .cancelled, entry.pendingIO == nil else { return }
    entries.removeValue(forKey: key)
    if phase == .drainingConnections, entries.isEmpty { phase = .stopped }
  }
}
