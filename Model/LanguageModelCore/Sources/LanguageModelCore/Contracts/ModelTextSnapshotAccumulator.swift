import Foundation

/// A pure value reducer for cumulative text snapshots. Exact UTF-8 prefixes
/// matter: String Character counts change when a combining mark is appended.
public struct ModelTextSnapshotAccumulator: Sendable {
  private enum State: Sendable {
    case awaitingFirstSnapshot
    case text(String)
  }
  private var state: State = .awaitingFirstSnapshot
  private let maximumOutputBytes: Int
  private let limits: ModelGenerationLimits

  public init(request: ModelRequest) {
    maximumOutputBytes = min(request.maxOutputBytes, request.limits.maxOutputBytes)
    limits = request.limits
  }

  public mutating func receive(_ snapshot: String) throws -> [String] {
    guard snapshot.utf8.count <= maximumOutputBytes else {
      throw ModelGenerationFailure(
        .limitExceeded, "The cumulative response exceeded the output byte limit.")
    }
    let previous: String
    switch state {
    case .awaitingFirstSnapshot: previous = ""
    case .text(let text): previous = text
    }
    guard snapshot.utf8.starts(with: previous.utf8) else {
      throw ModelGenerationFailure(
        .malformedEvent, "The cumulative response is not an exact UTF-8 extension.")
    }
    let suffix = String(decoding: snapshot.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
    let deltas = try limits.boundedDeltas(for: suffix)
    state = .text(snapshot)
    return deltas
  }

  public func finish() throws -> String {
    guard case .text(let text) = state else {
      throw ModelGenerationFailure(
        .terminalMissing, "The native response stream produced no snapshot.")
    }
    return text
  }
}
