import Foundation
import NativeAgentDomain

enum StoreArtifactIntegrity {
    /// Matches the runtime's supported per-artifact ceiling and prevents direct
    /// store clients from turning metadata into an unbounded file read.
    static let maximumByteCount = 512 * 1_024 * 1_024

    static func digestForWrite(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else {
            throw AgentError.budgetExceeded(
                "Artifact exceeds the store limit of \(maximumByteCount) bytes."
            )
        }
        return SHA256HexDigest.digest(data)
    }

    static func loadPayload(
        at url: URL,
        record: ArtifactRecord
    ) throws -> Data {
        try validateMetadata(record)
        try validateFileIdentity(at: url, record: record)
        let data = try StoreBoundedFileReader.read(
            from: url,
            maximumByteCount: record.byteCount,
            label: "artifact \(record.id)"
        )
        guard data.count == record.byteCount else {
            throw metadataMismatch(record.id)
        }
        let actual = SHA256HexDigest.digest(data)
        guard actual == record.contentSHA256 else {
            throw contentMismatch(record.id)
        }
        return data
    }

    static func validatePayload(
        at url: URL,
        record: ArtifactRecord
    ) throws {
        try validateMetadata(record)
        try validateFileIdentity(at: url, record: record)
        let actual = try StoreBoundedFileReader.digestAndCount(
            from: url,
            maximumByteCount: record.byteCount,
            label: "artifact \(record.id)"
        )
        guard actual.byteCount == record.byteCount else {
            throw metadataMismatch(record.id)
        }
        guard actual.digest == record.contentSHA256 else {
            throw contentMismatch(record.id)
        }
    }

    private static func validateMetadata(_ record: ArtifactRecord) throws {
        guard (0...maximumByteCount).contains(record.byteCount) else {
            throw AgentError.persistenceFailure(
                "Artifact \(record.id) has an unsupported byte count."
            )
        }
        let digest = record.contentSHA256
        let isLowercaseHex = digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
        guard digest.utf8.count == 64, isLowercaseHex else {
            throw AgentError.persistenceFailure(
                "Artifact \(record.id) has an invalid SHA-256 digest."
            )
        }
    }

    private static func validateFileIdentity(
        at url: URL,
        record: ArtifactRecord
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == record.byteCount else {
            throw metadataMismatch(record.id)
        }
    }

    private static func metadataMismatch(_ artifactID: String) -> AgentError {
        .persistenceFailure(
            "Artifact \(artifactID) payload is missing or does not match its metadata."
        )
    }

    private static func contentMismatch(_ artifactID: String) -> AgentError {
        .persistenceFailure(
            "Artifact \(artifactID) content digest does not match durable metadata."
        )
    }
}
