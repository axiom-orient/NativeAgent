import Foundation
import KnowledgePresentation

public extension ASKProjectionPresentationSelector {
    static func selectProjectionSlug(from grounding: TutorGrounding) -> String? {
        firstTutorProjectionSlug(from: grounding.citations.map(\.projectionSlug))
            ?? firstTutorProjectionSlug(from: grounding.results.map(\.projectionSlug))
    }

    static func selectProjectionSlug(from reply: TutorReply, fallbackScope: TutorScope? = nil) -> String? {
        firstTutorProjectionSlug(from: reply.citations.map(\.projectionSlug))
            ?? fallbackScope?.projectionSlug
    }

    private static func firstTutorProjectionSlug(from values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
