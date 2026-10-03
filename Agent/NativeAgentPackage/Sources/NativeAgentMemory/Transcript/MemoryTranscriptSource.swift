import NativeAgent
import Foundation

/// Pull-only view of the Agent's durable transcript.  Memory never becomes an
/// authority for this data and never subscribes to a runtime event bus.
public protocol MemoryTranscriptSource: Sendable {
    func journalRecord(sessionID: String) async throws -> AgentJournalRecord
    func messages(sessionID: String, offset: Int, limit: Int) async throws -> SessionMessagePage
}

extension AgentStorage: MemoryTranscriptSource {}
