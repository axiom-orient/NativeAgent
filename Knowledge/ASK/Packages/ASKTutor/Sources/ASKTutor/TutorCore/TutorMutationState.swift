import Foundation

enum TutorMutationScope: Sendable, Hashable, Comparable, CustomStringConvertible {
  case learner(String)
  case session(String)
  case practiceSet(String)

  var description: String {
    switch self {
    case .learner(let id): return "learner:\(id)"
    case .session(let id): return "session:\(id)"
    case .practiceSet(let id): return "practice:\(id)"
    }
  }

  static func < (lhs: TutorMutationScope, rhs: TutorMutationScope) -> Bool {
    lhs.description < rhs.description
  }
}

struct TutorMutationState: Sendable, Equatable {
  var activeScopes: Set<TutorMutationScope> = []
}

enum TutorMutationEvent: Sendable, Equatable {
  case acquire(Set<TutorMutationScope>)
  case release(Set<TutorMutationScope>)
}

enum TutorMutationReduction: Sendable, Equatable {
  case accepted(TutorMutationState)
  case conflict(Set<TutorMutationScope>)
}

enum TutorMutationReducer {
  static func reduce(
    state: TutorMutationState,
    event: TutorMutationEvent
  ) -> TutorMutationReduction {
    var next = state
    switch event {
    case .acquire(let scopes):
      let conflicts = next.activeScopes.intersection(scopes)
      guard conflicts.isEmpty else { return .conflict(conflicts) }
      next.activeScopes.formUnion(scopes)
      return .accepted(next)
    case .release(let scopes):
      return .accepted(releasing(state: state, scopes: scopes))
    }
  }

  static func releasing(
    state: TutorMutationState,
    scopes: Set<TutorMutationScope>
  ) -> TutorMutationState {
    var next = state
    next.activeScopes.subtract(scopes)
    return next
  }
}
