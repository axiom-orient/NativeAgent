import Foundation
import KnowledgeCore

public extension CanonicalJSON {
    static func dump<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try CanonicalJSON.data(for: value) + Data([0x0a])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func loadObject(from url: URL) throws -> Any {
        try CanonicalJSON.object(from: Data(contentsOf: url))
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let value = try CanonicalJSON.decode(T.self, from: Data(contentsOf: url))
        try (value as? any ASKValidatable)?.validate()
        return value
    }
}
