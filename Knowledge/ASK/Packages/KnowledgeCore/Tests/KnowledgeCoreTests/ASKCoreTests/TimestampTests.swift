import Foundation
import Testing
@testable import KnowledgeCore

struct ASKTimestampTests {
    @Test
    func parsesRFC3339WithoutFractionalSeconds() {
        let date = ASKTimestamp.parse("2026-04-07T10:00:10Z")
        #expect(date?.timeIntervalSince1970 == 1_775_556_010)
        #expect(ASKTimestamp.isValidRFC3339("2026-04-07T10:00:10Z"))
    }

    @Test
    func parsesRFC3339WithFractionalSeconds() {
        let date = ASKTimestamp.parse("2026-04-07T10:00:10.123Z")
        #expect(abs((date?.timeIntervalSince1970 ?? 0) - 1_775_556_010.123) < 0.000_001)
        #expect(ASKTimestamp.isValidRFC3339("2026-04-07T10:00:10.123Z"))
    }

    @Test
    func parsesRFC3339WithTimezoneOffset() throws {
        let utc = try #require(ASKTimestamp.parse("2026-04-07T10:00:10Z"))
        let offset = try #require(ASKTimestamp.parse("2026-04-07T19:00:10+09:00"))
        #expect(offset == utc)
        #expect(ASKTimestamp.isValidRFC3339("2026-04-07T19:00:10+09:00"))
    }

    @Test
    func rejectsInvalidRFC3339() {
        #expect(ASKTimestamp.parse("2026-04-07 10:00:10") == nil)
        #expect(ASKTimestamp.parse("not-a-timestamp") == nil)
        #expect(!ASKTimestamp.isValidRFC3339("2026-04-07 10:00:10"))
        #expect(!ASKTimestamp.isValidRFC3339("not-a-timestamp"))
    }
}
