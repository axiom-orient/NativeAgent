import LanguageModelCore

/// Pure conversation transitions. This owns no executor, task, clock or I/O.
/// The actor interprets admission/cancel effects; only settled success commits.
struct SessionLedger: Sendable {
  struct Pending: Sendable {
    let generation: UInt64
    let input: [AgentMessage]
  }
  enum Phase: Sendable {
    case ready
    case generating(Pending)
    case closing
    case closed
    case failed
  }
  enum Event: Sendable {
    case begin([AgentMessage])
    case succeeded(UInt64, ModelTurn)
    case failed(UInt64)
    case close
    case didClose
    case closeFailed
  }
  enum Effect: Sendable {
    case generate(UInt64, [AgentMessage])
    case cancel
    case discarded
  }

  var transcript: [AgentMessage]
  var generation: UInt64 = 0
  var phase: Phase = .ready

  static func reduce(state: Self, event: Event) throws -> (Self, Effect?) {
    var next = state
    switch event {
    case .begin(let input):
      switch state.phase {
      case .ready: break
      case .generating: throw ModelRuntimeFailure(.busy, "This conversation is already generating.")
      case .closing: throw ModelRuntimeFailure(.closing, "This conversation is closing.")
      case .closed, .failed: throw ModelRuntimeFailure(.closed, "This conversation is closed.")
      }
      let (generation, overflow) = state.generation.addingReportingOverflow(1)
      guard !overflow else {
        throw ModelRuntimeFailure(
          .invariantViolation, "Conversation generation identity exhausted.")
      }
      next.generation = generation
      next.phase = .generating(.init(generation: generation, input: input))
      return (next, .generate(generation, state.transcript + input))
    case .succeeded(let generation, let turn):
      guard case .generating(let pending) = state.phase, pending.generation == generation else {
        return (state, .discarded)
      }
      next.transcript += pending.input
      let existingIDs = Set(next.transcript.map(\.id))
      let baseID = "model-response-\(generation)"
      var responseID = baseID
      var suffix: UInt64 = 0
      // A resumed/imported transcript may already use this session's deterministic
      // prefix. Keep all supplied identities intact; choose only a fresh reply ID.
      while existingIDs.contains(responseID) {
        suffix += 1
        responseID = "\(baseID)-\(suffix)"
      }
      next.transcript.append(
        AgentMessage(
          id: responseID, role: .assistant, contentParts: turn.contentParts,
          toolCalls: turn.toolCalls, metadata: turn.metadata, usage: turn.usage,
          responseID: turn.responseID,
          reasoningSummary: turn.reasoningSummary, stopReason: turn.stopReason))
      next.phase = .ready
    case .failed(let generation):
      guard case .generating(let pending) = state.phase, pending.generation == generation else {
        return (state, .discarded)
      }
      next.phase = .ready
    case .close:
      switch state.phase {
      case .closing, .closed, .failed: return (state, nil)
      case .ready, .generating: next.phase = .closing
      }
      return (next, .cancel)
    case .didClose:
      guard case .closing = state.phase else { return (state, .discarded) }
      next.phase = .closed
    case .closeFailed:
      guard case .closing = state.phase else { return (state, .discarded) }
      next.phase = .failed
    }
    return (next, nil)
  }
}
