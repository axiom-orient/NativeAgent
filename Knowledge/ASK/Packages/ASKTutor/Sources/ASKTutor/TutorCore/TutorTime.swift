import Foundation
import KnowledgeCore

package enum TutorTime {
    package static func parse(_ value: String) -> Date? {
        ASKTimestamp.parse(value)
    }

    package static func format(_ date: Date) -> String {
        date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
    }
}
