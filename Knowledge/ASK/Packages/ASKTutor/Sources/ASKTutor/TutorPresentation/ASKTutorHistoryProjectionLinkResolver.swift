import KnowledgePresentation
import Foundation

struct ASKTutorHistoryProjectionLinkResolver: Sendable {
    let runtime: ASKProductReadRuntime

    func scopePresentation(
        sessionID: String,
        scope: TutorScope
    ) async throws -> TutorSessionScopePresentation {
        TutorSessionScopePresentation(
            sessionID: sessionID,
            scope: scope,
            projectionLink: try await projectionLink(projectionSlug: scope.projectionSlug)
        )
    }

    func citationLinks(_ citations: [TutorCitation]) async throws -> [TutorProjectionLink] {
        var links: [TutorProjectionLink] = []
        links.reserveCapacity(citations.count)
        for citation in citations {
            links.append(
                try await projectionLink(
                    projectionSlug: citation.projectionSlug
                )
            )
        }
        return links
    }

    func projectionLink(projectionSlug: String?) async throws -> TutorProjectionLink {
        guard let projectionSlug,
              !projectionSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return TutorProjectionLink(
                projectionSlug: nil,
                readingContext: nil,
                status: .noProjection
            )
        }

        do {
            let readingContext = try await runtime.loadProjectionReadingContext(slug: projectionSlug)
            return TutorProjectionLink(
                projectionSlug: projectionSlug,
                readingContext: readingContext,
                status: .linked
            )
        } catch ASKProductIntegrationError.projectionNotFound {
            return TutorProjectionLink(
                projectionSlug: projectionSlug,
                readingContext: nil,
                status: .projectionNotFound
            )
        }
    }
}
