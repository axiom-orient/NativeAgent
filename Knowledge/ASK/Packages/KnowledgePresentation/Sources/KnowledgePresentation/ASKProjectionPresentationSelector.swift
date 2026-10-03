import Foundation
import KnowledgeRuntime

public enum ASKProjectionPresentationSelector {
    public static func selectProjectionSlug(from queryResult: QueryResult) -> String? {
        firstProjectionSlug(from: queryResult.citations.map(\.projectionSlug))
            ?? firstProjectionSlug(from: queryResult.results.map(\.projectionSlug))
    }

    package static func firstProjectionSlug(from values: [String?]) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
