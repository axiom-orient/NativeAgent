import Foundation

/// One ordered event from a model invocation. A provider can expose true
/// transport deltas; the protocol's default implementation emits a started and
/// completed event around the existing one-shot `generate` contract.
///
/// `started` is the authoritative provider-effect boundary. A provider that
/// overrides `stream(request:)` must complete side-effect-free request/policy
/// validation before emitting it, and must emit it before native/model/network
/// work whose outcome may become uncertain. Runtime code must not infer effect
/// certainty merely from creation of a `ModelRun`.
public enum ModelEvent: Sendable, Equatable {
    case started(descriptor: ModelDescriptor?)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(id: String, name: String?, argumentsDelta: String)
    case usage(ModelUsage)
    case completed(ModelTurn)

    public var hasVisibleOutput: Bool {
        switch self {
        case let .textDelta(value), let .reasoningDelta(value): !value.isEmpty
        case .toolCallDelta, .completed: true
        case .started, .usage: false
        }
    }
}
