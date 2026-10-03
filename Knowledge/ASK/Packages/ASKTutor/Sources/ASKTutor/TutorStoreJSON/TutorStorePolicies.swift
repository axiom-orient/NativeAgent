
enum TutorStoreMergeDecision<Value: Sendable>: Sendable {
    case keepExisting
    case saveIncoming(Value)
}

enum TutorStoreMergePolicies {
    static func decision<Value: Equatable & Sendable>(
        existing: Value?,
        incoming: Value,
        identity: String,
        mergePolicy: TutorDataArchiveMergePolicy
    ) throws -> TutorStoreMergeDecision<Value> {
        guard let existing else {
            return .saveIncoming(incoming)
        }

        guard existing != incoming else {
            return .keepExisting
        }

        switch mergePolicy {
        case .failOnConflict:
            throw ASKTutorError.storage("archive conflict for `\(identity)`")
        case .keepExisting:
            return .keepExisting
        case .replaceExisting:
            return .saveIncoming(incoming)
        }
    }
}

enum TutorStoreRecencyPolicies {
    static func isMoreRecent<Value>(
        _ lhs: Value,
        _ rhs: Value,
        timestamp: KeyPath<Value, String>,
        tieBreaker: KeyPath<Value, String>
    ) -> Bool {
        let leftTimestamp = lhs[keyPath: timestamp]
        let rightTimestamp = rhs[keyPath: timestamp]
        let leftDate = TutorTime.parse(leftTimestamp)
        let rightDate = TutorTime.parse(rightTimestamp)

        switch (leftDate, rightDate) {
        case let (left?, right?) where left != right:
            return left > right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            if leftTimestamp != rightTimestamp {
                return leftTimestamp > rightTimestamp
            }
            return lhs[keyPath: tieBreaker] < rhs[keyPath: tieBreaker]
        }
    }
}
