import Foundation
import NativeAgentDomain

func nativeAgentISO8601String(from date: Date) -> String {
    makePreciseNativeAgentISO8601Formatter().string(from: date)
}

func parseNativeAgentISO8601Date(_ value: String) throws -> Date {
    let precise = makePreciseNativeAgentISO8601Formatter()
    let fallback = ISO8601DateFormatter()

    if let date = precise.date(from: value) ?? fallback.date(from: value) {
        return date
    }
    throw AgentError.invalidToolCall("Invalid ISO-8601 date-time: \(value)")
}

private func makePreciseNativeAgentISO8601Formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}
