import LanguageModelCore
import Foundation

/// Durable cursor for a bounded model-context projection.
///
/// Messages before `coveredMessageCount`, except for the leading system block,
/// remain in the durable transcript but are represented to the model by
/// `summaryMessage`.
public struct SessionContextCheckpoint: Codable, Sendable, Equatable {
    public let preservedSystemMessageCount: Int
    public let coveredMessageCount: Int
    public let summaryMessage: AgentMessage

    public init(
        preservedSystemMessageCount: Int,
        coveredMessageCount: Int,
        summaryMessage: AgentMessage
    ) {
        self.preservedSystemMessageCount = preservedSystemMessageCount
        self.coveredMessageCount = coveredMessageCount
        self.summaryMessage = summaryMessage
    }
}
