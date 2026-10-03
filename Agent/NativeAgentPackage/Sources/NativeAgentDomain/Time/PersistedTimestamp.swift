import LanguageModelCore
import Foundation

/// Canonical timestamp precision used by NativeAgent's JSON persistence contract.
///
/// `JSONEncoder.nativeAgent()` converts seconds to milliseconds since 1970. For some
/// sub-millisecond `Date` values, that multiply/divide round trip changes the
/// exact `Double` value even though the represented instant is effectively the
/// same. Runtime state therefore truncates timestamps to an integral millisecond
/// before they enter a durable transition.
package enum PersistedTimestamp {
    package static func canonicalizing(_ date: Date) -> Date {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            return date
        }
        return Date(timeIntervalSince1970: Double(Int64(milliseconds)) / 1_000)
    }

    package static func clock(
        _ source: @escaping @Sendable () -> Date
    ) -> @Sendable () -> Date {
        { canonicalizing(source()) }
    }
}
