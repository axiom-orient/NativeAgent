import Foundation

enum ASKWorkWikiMutationOperation: String, Sendable, Equatable {
  case importCapture
  case captureEvidence
  case stageReport
  case approveReport
  case rejectReport
  case closeDay
}

enum ASKWorkWikiMutationState: Sendable, Equatable {
  case idle
  case active(ASKWorkWikiMutationOperation)
}

enum ASKWorkWikiMutationEvent: Sendable, Equatable {
  case begin(ASKWorkWikiMutationOperation)
  case finish(ASKWorkWikiMutationOperation)
}

enum ASKWorkWikiMutationReduction: Sendable, Equatable {
  case accepted(ASKWorkWikiMutationState)
  case conflict(active: ASKWorkWikiMutationOperation, requested: ASKWorkWikiMutationOperation)
}

enum ASKWorkWikiMutationReducer {
  static func reduce(
    state: ASKWorkWikiMutationState,
    event: ASKWorkWikiMutationEvent
  ) -> ASKWorkWikiMutationReduction {
    switch (state, event) {
    case (.idle, .begin(let operation)):
      return .accepted(.active(operation))
    case (.active(let active), .begin(let requested)):
      return .conflict(active: active, requested: requested)
    case (_, .finish(let operation)):
      return .accepted(finishing(state: state, operation: operation))
    }
  }

  static func finishing(
    state: ASKWorkWikiMutationState,
    operation: ASKWorkWikiMutationOperation
  ) -> ASKWorkWikiMutationState {
    guard case .active(operation) = state else { return state }
    return .idle
  }
}
