public enum GoalStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case paused
    case waiting
    case complete
    case budgetLimited = "budget_limited"
    case blocked
    case failed
    case cleared

    public var isTerminal: Bool {
        switch self {
        case .complete, .budgetLimited, .blocked, .failed, .cleared:
            true
        case .active, .paused, .waiting:
            false
        }
    }
}
