import Foundation
import LanguageModelCore

public struct ModelRuntimeID: RawRepresentable, Codable, Hashable, Sendable {
  public static let maximumUTF8Bytes = 256
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct ModelRunID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

/// Ephemeral authority to start one already-admitted model invocation.
///
/// A durable orchestrator can reserve the runtime slot, persist its own
/// invocation receipt, and only then exchange this capability for a `ModelRun`.
/// Reservations are process-local and intentionally not codable.
public struct ModelRunReservation: Hashable, Sendable {
  public let runtimeID: ModelRuntimeID
  public let runID: ModelRunID

}

public enum ModelRunEffectState: Sendable, Equatable {
  /// The runtime has not observed the provider's authoritative `started` event.
  case notStarted
  /// The provider crossed its declared effect boundary.
  case started
}

public enum ModelRuntimePhase: String, Codable, Hashable, Sendable {
  case idle
  case reserved
  case running
  case draining
  case closing
  case closed
  case failed
}

public enum ModelRuntimeDrainReason: String, Codable, Hashable, Sendable {
  case cancellation
  case consumerTermination
  case deadlineExceeded
  case shutdown
}

public struct ModelRuntimeStatus: Codable, Hashable, Sendable {
  public let phase: ModelRuntimePhase
  public let activeRunID: ModelRunID?
  public let drainReason: ModelRuntimeDrainReason?
  public let failure: ModelRuntimeFailure?

  public init(
    phase: ModelRuntimePhase,
    activeRunID: ModelRunID? = nil,
    drainReason: ModelRuntimeDrainReason? = nil,
    failure: ModelRuntimeFailure? = nil
  ) {
    precondition(
      Self.hasValidShape(
        phase: phase,
        activeRunID: activeRunID,
        drainReason: drainReason,
        failure: failure
      ),
      "ModelRuntimeStatus contains a phase-incompatible payload."
    )
    self.phase = phase
    self.activeRunID = activeRunID
    self.drainReason = drainReason
    self.failure = failure
  }

  private enum CodingKeys: String, CodingKey {
    case phase
    case activeRunID
    case drainReason
    case failure
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let phase = try container.decode(ModelRuntimePhase.self, forKey: .phase)
    let activeRunID = try container.decodeIfPresent(ModelRunID.self, forKey: .activeRunID)
    let drainReason = try container.decodeIfPresent(
      ModelRuntimeDrainReason.self, forKey: .drainReason)
    let failure = try container.decodeIfPresent(ModelRuntimeFailure.self, forKey: .failure)

    guard
      Self.hasValidShape(
        phase: phase,
        activeRunID: activeRunID,
        drainReason: drainReason,
        failure: failure
      )
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .phase,
        in: container,
        debugDescription: "ModelRuntimeStatus contains a phase-incompatible payload."
      )
    }

    self.phase = phase
    self.activeRunID = activeRunID
    self.drainReason = drainReason
    self.failure = failure
  }

  private static func hasValidShape(
    phase: ModelRuntimePhase,
    activeRunID: ModelRunID?,
    drainReason: ModelRuntimeDrainReason?,
    failure: ModelRuntimeFailure?
  ) -> Bool {
    switch phase {
    case .idle, .closed:
      return activeRunID == nil && drainReason == nil && failure == nil
    case .reserved, .running:
      return activeRunID != nil && drainReason == nil && failure == nil
    case .draining:
      return activeRunID != nil && drainReason != nil && failure == nil
    case .closing:
      guard failure == nil else { return false }
      if activeRunID == nil { return drainReason == nil }
      return drainReason == .shutdown
    case .failed:
      return drainReason == nil && failure != nil
    }
  }
}

public enum ModelRuntimeFailureCode: String, Codable, Hashable, Sendable {
  case invalidConfiguration
  case invalidReservation
  case busy
  case closing
  case closed
  case shutdownDrainTimedOut
  case cleanupFailed
  case nativeDrainFailed
  case invariantViolation
}

public struct ModelRuntimeFailure: Error, LocalizedError, Codable, Hashable, Sendable {
  public static let maximumMessageUTF8Bytes = 4 * 1_024
  public let code: ModelRuntimeFailureCode
  public let message: String

  public init(_ code: ModelRuntimeFailureCode, _ message: String) {
    self.code = code
    self.message = Self.bounded(message)
  }

  public var errorDescription: String? {
    "\(code.rawValue): \(message)"
  }

  private static func bounded(_ value: String) -> String {
    var bytes = Array(value.utf8.prefix(Self.maximumMessageUTF8Bytes))
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
      bytes.removeLast()
    }
    return String(bytes: bytes, encoding: .utf8) ?? "Model runtime failed."
  }
}

public struct ModelRuntimePolicy: Sendable {
  public static let standardMaximumEventCount = 16_384
  public static let standardShutdownDrainTimeout: Duration = .seconds(5)
  public static let standardDrainPollInterval: Duration = .milliseconds(10)
  public static let minimumEventCount = 2
  public static let supportedMaximumEventCount = 65_536
  public static let supportedMaximumShutdownDrainTimeout: Duration = .seconds(60)

  public let maximumEventCount: Int
  public let shutdownDrainTimeout: Duration
  public let drainPollInterval: Duration

  public static let `default` = try! Self()

  public init(
    maximumEventCount: Int = Self.standardMaximumEventCount,
    shutdownDrainTimeout: Duration = Self.standardShutdownDrainTimeout,
    drainPollInterval: Duration = Self.standardDrainPollInterval
  ) throws {
    guard (Self.minimumEventCount...Self.supportedMaximumEventCount).contains(maximumEventCount),
      shutdownDrainTimeout > .zero,
      shutdownDrainTimeout <= Self.supportedMaximumShutdownDrainTimeout,
      drainPollInterval > .zero,
      drainPollInterval <= shutdownDrainTimeout
    else {
      throw ModelRuntimeFailure(
        .invalidConfiguration,
        "Model runtime policy is outside its supported bounds."
      )
    }
    self.maximumEventCount = maximumEventCount
    self.shutdownDrainTimeout = shutdownDrainTimeout
    self.drainPollInterval = drainPollInterval
  }
}

public struct ModelRun: Sendable {
  public let id: ModelRunID
  public let events: AsyncThrowingStream<ModelEvent, any Error>
  /// Cancels and joins this runtime's provider-consumption pump. Buffered adapter
  /// producers/native drains remain provider-owned; remote effects are not undone.
  public let cancel: @Sendable () async -> Void
  private let effectStateValue: @Sendable () -> ModelRunEffectState

  public init(
    id: ModelRunID,
    events: AsyncThrowingStream<ModelEvent, any Error>,
    cancel: @escaping @Sendable () async -> Void,
    effectState: @escaping @Sendable () -> ModelRunEffectState = { .notStarted }
  ) {
    self.id = id
    self.events = events
    self.cancel = cancel
    self.effectStateValue = effectState
  }

  /// Synchronously reports whether the provider crossed its ModelEvent.started
  /// boundary. This remains queryable after the stream terminates.
  public var effectState: ModelRunEffectState { effectStateValue() }
}
