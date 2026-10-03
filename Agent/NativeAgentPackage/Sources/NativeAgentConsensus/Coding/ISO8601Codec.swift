import Foundation

enum ISO8601Codec {
    static func parse(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }

    static func string(from date: Date) -> String {
        date.formatted(.iso8601)
    }
}
