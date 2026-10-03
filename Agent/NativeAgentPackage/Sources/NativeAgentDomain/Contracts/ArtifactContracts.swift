import LanguageModelCore
import Foundation

public struct ArtifactWriteRequest: Codable, Sendable, Equatable, Hashable {
    public let preferredFilename: String
    public let mimeType: String
    public let data: Data
    public let metadata: [String: JSONValue]

    public init(
        preferredFilename: String,
        mimeType: String,
        data: Data,
        metadata: [String: JSONValue] = [:]
    ) {
        self.preferredFilename = preferredFilename
        self.mimeType = mimeType
        self.data = data
        self.metadata = metadata
    }
}

public struct ArtifactRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let sessionID: String
    public let filename: String
    public let relativePath: String
    public let mimeType: String
    public let byteCount: Int
    public let contentSHA256: String
    public let createdAt: Date
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        sessionID: String,
        filename: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        contentSHA256: String,
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.filename = filename
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
        self.createdAt = createdAt
        self.metadata = metadata
    }

    public init(
        sessionID: String,
        filename: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        contentSHA256: String,
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        metadata: [String: JSONValue] = [:]
    ) {
        self.init(
            id: DeterministicCoreDefaults.identifier(
                prefix: "artifact",
                components: [
                    sessionID,
                    filename,
                    relativePath,
                    mimeType,
                    String(byteCount),
                    contentSHA256,
                    DeterministicCoreDefaults.dateComponent(createdAt),
                    DeterministicCoreDefaults.metadataComponent(metadata)
                ]
            ),
            sessionID: sessionID,
            filename: filename,
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: byteCount,
            contentSHA256: contentSHA256,
            createdAt: createdAt,
            metadata: metadata
        )
    }
}
