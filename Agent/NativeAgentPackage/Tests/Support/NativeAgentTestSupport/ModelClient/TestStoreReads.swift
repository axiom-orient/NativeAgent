import Foundation
import NativeAgentDomain
import NativeAgentStore

public extension ApplicationSupportSessionStore {
    func testFirstSessionID() async throws -> String? {
        try await listSessionSummaries(limit: 1, offset: 0).first?.sessionID
    }

    func testFirstSnapshot() async throws -> SessionSnapshot? {
        guard let sessionID = try await testFirstSessionID() else { return nil }
        return try await loadSnapshot(sessionID: sessionID)
    }
}
