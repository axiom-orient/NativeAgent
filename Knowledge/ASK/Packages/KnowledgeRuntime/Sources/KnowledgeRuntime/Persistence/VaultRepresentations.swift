import Foundation
import KnowledgeCore

extension Vault {
    package func representationDirectory(sourceID: String) throws -> URL {
        try ASKValidation.requirePathSafeID("source_id", sourceID)
        return root.appendingPathComponent("records/representations/\(sourceID)", isDirectory: true)
    }

    package func representationURL(sourceID: String, kind: RepresentationKind) throws -> URL {
        try representationDirectory(sourceID: sourceID).appendingPathComponent("\(kind.rawValue).json", isDirectory: false)
    }

    package func writeRepresentation(_ record: RepresentationRecord) throws {
        try record.validate()
        try writeJSONFile(try representationURL(sourceID: record.sourceID, kind: record.kind), payload: record)
    }

    package func loadRepresentation(sourceID: String, kind: RepresentationKind) throws -> RepresentationRecord? {
        let url = try representationURL(sourceID: sourceID, kind: kind)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try CanonicalJSON.load(RepresentationRecord.self, from: url)
    }

    package func listRepresentations(sourceID: String) throws -> [RepresentationRecord] {
        let directory = try representationDirectory(sourceID: sourceID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try CanonicalJSON.load(RepresentationRecord.self, from: $0) }
    }
}
