import Foundation
import NativeAgentDomain

enum StoreCodecs {
    static func makeEncoder() -> JSONEncoder {
        JSONEncoder.nativeAgent()
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder.nativeAgent()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maximumByteCount: Int = StoreBoundedFileReader.defaultJSONLimit
    ) throws -> T {
        try decode(
            type,
            from: StoreBoundedFileReader.read(
                from: url,
                maximumByteCount: maximumByteCount,
                label: url.lastPathComponent
            )
        )
    }

    static func write<T: Encodable>(
        _ value: T,
        to url: URL,
        maximumByteCount: Int = StoreBoundedFileReader.defaultJSONLimit
    ) throws {
        guard maximumByteCount >= 0 else {
            throw AgentError.invalidConfiguration(
                "\(url.lastPathComponent) maximum byte count must be nonnegative."
            )
        }
        let data = try encode(value)
        guard data.count <= maximumByteCount else {
            throw AgentError.budgetExceeded(
                "\(url.lastPathComponent) exceeds \(maximumByteCount) bytes."
            )
        }
        try data.write(to: url, options: .atomic)
    }
}

public struct StoreManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let createdAt: Date

    public init(
        schemaVersion: Int = StoreManifest.currentSchemaVersion,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}
