/// Actor-owned admission state. It stays occupied across native suspension points.
/// Task cancellation does not release the slot; the native await must return first.
enum LEAPRuntimeActivity: Equatable, Sendable {
  case idle
  case loading
  case generating
  case unloading

  var isBusy: Bool { self != .idle }
}
