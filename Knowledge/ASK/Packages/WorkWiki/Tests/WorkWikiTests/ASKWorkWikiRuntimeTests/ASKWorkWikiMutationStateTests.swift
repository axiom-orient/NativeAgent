import Testing

@testable import WorkWiki

struct ASKWorkWikiMutationStateTests {
  @Test
  func mutationReducerSerializesEffectfulWorkflows() {
    let first = ASKWorkWikiMutationReducer.reduce(
      state: .idle,
      event: .begin(.stageReport)
    )
    #expect(first == .accepted(.active(.stageReport)))

    guard case .accepted(let active) = first else {
      Issue.record("Expected the first mutation to acquire the runtime")
      return
    }

    let conflict = ASKWorkWikiMutationReducer.reduce(
      state: active,
      event: .begin(.closeDay)
    )
    #expect(conflict == .conflict(active: .stageReport, requested: .closeDay))

    let finished = ASKWorkWikiMutationReducer.reduce(
      state: active,
      event: .finish(.stageReport)
    )
    #expect(finished == .accepted(.idle))
  }

  @Test
  func unrelatedFinishCannotReleaseActiveMutation() {
    let state = ASKWorkWikiMutationState.active(.approveReport)
    let next = ASKWorkWikiMutationReducer.finishing(
      state: state,
      operation: .rejectReport
    )
    #expect(next == state)
  }
}
