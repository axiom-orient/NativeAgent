import Foundation

enum ScriptedRoundResolver {
    static func sleepIfNeeded(_ delayNanoseconds: UInt64) async throws {
        guard delayNanoseconds > 0 else { return }
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }

    static func value<T>(round: Int, from values: [T], actor: String) throws -> T {
        guard round > 0, round <= values.count else {
            throw ScriptedError.missingRound(actor: actor, round: round)
        }
        return values[round - 1]
    }
}
