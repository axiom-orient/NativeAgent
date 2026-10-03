import Foundation
import KnowledgeCore

public struct TutorInsightCandidateStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    @discardableResult
    public func save(_ candidate: TutorInsightCandidate, fileManager: FileManager = .default) throws -> URL {
        let url = try candidateFileURL(candidate.candidateID)
        return try TutorJSONDirectoryStore.save(candidate, to: url, rootURL: rootURL, fileManager: fileManager)
    }

    public func load(candidateID: String, fileManager: FileManager = .default) throws -> TutorInsightCandidate? {
        let url = try candidateFileURL(candidateID)
        return try TutorJSONDirectoryStore.load(TutorInsightCandidate.self, from: url)
    }

    public func list(fileManager: FileManager = .default) throws -> [TutorInsightCandidate] {
        try TutorJSONDirectoryStore.list(TutorInsightCandidate.self, in: rootURL, fileManager: fileManager)
            .sorted {
                switch ASKTimestamp.compare($0.createdAt, $1.createdAt) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return $0.candidateID < $1.candidateID
                }
            }
    }

    public func remove(candidateID: String, fileManager: FileManager = .default) throws {
        do {
            try fileManager.removeItem(at: try candidateFileURL(candidateID))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func candidateFileURL(_ candidateID: String) throws -> URL {
        let normalized = try askProductNormalizedTutorInsightCandidateID(candidateID)
        return rootURL.appendingPathComponent("\(normalized).json", isDirectory: false)
    }
}
