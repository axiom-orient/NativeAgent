import Foundation
import Testing
@testable import KnowledgeCore

struct TimestampOrderingTests {
    @Test
    func offsetTimestampsAreOrderedByInstantNotByText() {
        // 19:00+09:00 is 10:00Z, so it precedes 12:00Z even though it sorts after it.
        #expect(ASKTimestamp.isBefore("2026-04-07T19:00:00+09:00", "2026-04-07T12:00:00Z"))
        #expect("2026-04-07T19:00:00+09:00" > "2026-04-07T12:00:00Z")
    }

    @Test
    func fractionalSecondsAreOrderedByInstantNotByText() {
        #expect(ASKTimestamp.isBefore("2026-04-07T10:00:00Z", "2026-04-07T10:00:00.500Z"))
        #expect("2026-04-07T10:00:00.500Z" < "2026-04-07T10:00:00Z")
    }

    @Test
    func equalInstantsFallBackToStableTextOrder() {
        let utc = "2026-04-07T10:00:00Z"
        let offset = "2026-04-07T19:00:00+09:00"
        #expect(ASKTimestamp.compare(utc, utc) == .orderedSame)
        #expect(ASKTimestamp.compare(utc, offset) == (utc < offset ? .orderedAscending : .orderedDescending))
        #expect(ASKTimestamp.compare(offset, utc) == (offset < utc ? .orderedAscending : .orderedDescending))
    }

    @Test
    func unparseableValuesKeepATotalOrder() {
        #expect(ASKTimestamp.compare("not-a-timestamp", "2026-04-07T10:00:00Z") == .orderedDescending)
        #expect(ASKTimestamp.compare("2026-04-07T10:00:00Z", "not-a-timestamp") == .orderedAscending)
        #expect(ASKTimestamp.compare("aaa", "aaa") == .orderedSame)
    }

    @Test
    func openEndedSentinelSortsAfterEveryValidTimestamp() {
        #expect(ASKTimestamp.isValidRFC3339(ASKTimestamp.openEndedSentinel))
        #expect(ASKTimestamp.isBefore("2999-01-01T00:00:00Z", ASKTimestamp.openEndedSentinel))
    }

    @Test
    func authorityIntervalValidationUsesInstantOrder() throws {
        // effective_to is 10:00Z, one hour before effective_from at 11:00Z, but its
        // text sorts later; instant ordering must still reject the interval.
        let record = AuthorityRecord(
            version: "1",
            recordID: "auth_interval",
            recordType: "runtime",
            subjectKind: "runtime",
            subjectID: "ask-runtime",
            factScopeKey: "runtime_state",
            approvalState: .approved,
            valueFields: ["state": "ok"],
            effectiveFrom: "2026-04-07T11:00:00Z",
            effectiveTo: "2026-04-07T19:00:00+09:00",
            approvedBy: "owner",
            supersedesID: nil
        )
        #expect(throws: ASKError.self) {
            try record.validate()
        }
    }

    @Test
    func orderKeyMatchesCompareIncludingTheFastPath() {
        let values = [
            "2026-04-07T10:00:00Z",
            "2026-04-07T12:00:00Z",
            "2026-04-07T19:00:00+09:00",
            "2026-04-07T10:00:00.500Z",
            "9999-12-31T23:59:59Z",
            "not-a-timestamp",
        ]
        #expect(ASKTimestamp.isPlainUTCSeconds("2026-04-07T10:00:00Z"))
        #expect(!ASKTimestamp.isPlainUTCSeconds("2026-04-07T10:00:00.500Z"))
        #expect(!ASKTimestamp.isPlainUTCSeconds("2026-04-07T19:00:00+09:00"))

        for left in values {
            for right in values {
                let keyOrder = ASKTimestamp.OrderKey(left) < ASKTimestamp.OrderKey(right)
                #expect(keyOrder == (ASKTimestamp.compare(left, right) == .orderedAscending))
            }
        }
    }

    @Test
    func operationLogOrderUsesInstantThenLogID() {
        let early = OperationLogEntry(logID: "log_b", occurredAt: "2026-04-07T19:00:00+09:00", opKind: "k", summary: "s")
        let late = OperationLogEntry(logID: "log_a", occurredAt: "2026-04-07T12:00:00Z", opKind: "k", summary: "s")
        let tie = OperationLogEntry(logID: "log_c", occurredAt: "2026-04-07T12:00:00Z", opKind: "k", summary: "s")

        let ordered = OperationLogEntry.canonicallyOrdered([late, tie, early])
        #expect(ordered.map(\.logID) == ["log_b", "log_a", "log_c"])
    }
}
