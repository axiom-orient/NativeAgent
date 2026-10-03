import Foundation

public enum ASKTimestamp {
    private static let styleWithFractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let styleWithoutFractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    /// Stands in for "no end yet" / "not decided yet" wherever an open-ended
    /// interval has to take part in an ordering.
    public static let openEndedSentinel = "9999-12-31T23:59:59Z"

    public static func isValidRFC3339(_ value: String) -> Bool {
        parse(value) != nil
    }

    public static func parse(_ value: String) -> Date? {
        if let value = try? styleWithFractional.parse(value) {
            return value
        }
        return try? styleWithoutFractional.parse(value)
    }

    /// Chronological order for two RFC3339 timestamps.
    ///
    /// Comparing the strings directly is wrong for the timestamps this project
    /// accepts: `2026-04-07T19:00:00+09:00` is earlier than `2026-04-07T12:00:00Z`
    /// but sorts after it, and `…:00.500Z` sorts before `…:00Z` because `.`
    /// precedes `Z`. Equal instants and unparseable values fall back to string
    /// order so every ordering built on this stays total and deterministic.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        guard let left = parse(lhs), let right = parse(rhs), left != right else {
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
        return left < right ? .orderedAscending : .orderedDescending
    }

    public static func isBefore(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// `YYYY-MM-DDThh:mm:ssZ` exactly: fixed width, UTC, no fractional seconds.
    /// Two such values compare chronologically as plain text.
    static func isPlainUTCSeconds(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 20 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 4, 7: if byte != UInt8(ascii: "-") { return false }
            case 10: if byte != UInt8(ascii: "T") { return false }
            case 13, 16: if byte != UInt8(ascii: ":") { return false }
            case 19: if byte != UInt8(ascii: "Z") { return false }
            default: if byte < UInt8(ascii: "0") || byte > UInt8(ascii: "9") { return false }
            }
        }
        return true
    }

    /// Pre-parsed sort key with the same ordering as `compare`.
    ///
    /// Parsing RFC3339 is expensive enough to dominate a sort that parses inside
    /// the comparator, so anything sorting more than a handful of timestamps
    /// builds one key per element instead.
    public struct OrderKey: Comparable, Sendable {
        public let text: String
        private let isPlainUTCSeconds: Bool
        private let instant: Date?

        public init(_ text: String) {
            self.text = text
            self.isPlainUTCSeconds = ASKTimestamp.isPlainUTCSeconds(text)
            // `YYYY-MM-DDThh:mm:ssZ` values order the same way as text, which is
            // what this project writes, so the common case never pays for a parse.
            self.instant = isPlainUTCSeconds ? nil : ASKTimestamp.parse(text)
        }

        public static func < (lhs: OrderKey, rhs: OrderKey) -> Bool {
            if lhs.isPlainUTCSeconds && rhs.isPlainUTCSeconds {
                return lhs.text < rhs.text
            }
            let left = lhs.instant ?? ASKTimestamp.parse(lhs.text)
            let right = rhs.instant ?? ASKTimestamp.parse(rhs.text)
            if let left, let right, left != right {
                return left < right
            }
            return lhs.text < rhs.text
        }

        public static func == (lhs: OrderKey, rhs: OrderKey) -> Bool {
            lhs.text == rhs.text
        }
    }

    public static func isAtOrBefore(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) != .orderedDescending
    }
}
