internal import NativeAgentMemoryProjection
import Foundation

public struct MemoryConfiguration: Sendable, Equatable {
    public let dataDirectory: URL
    public let defaultProfileID: String
    public let defaultUserID: String
    public let maxContextResults: Int
    public let namespace: String

    public init(
        dataDirectory: URL,
        defaultProfileID: String = "default",
        defaultUserID: String = "default",
        maxContextResults: Int = 8,
        namespace: String = ""
    ) {
        self.dataDirectory = dataDirectory
        self.defaultProfileID = defaultProfileID
        self.defaultUserID = defaultUserID
        self.maxContextResults = min(max(1, maxContextResults), 8)
        self.namespace = namespace
    }

    var agentMemoryConfiguration: AgentMemoryConfiguration {
        AgentMemoryConfiguration(
            dataDirectory: dataDirectory,
            defaultProfileID: defaultProfileID,
            defaultUserID: defaultUserID,
            namespace: namespace
        )
    }
}
