import KnowledgePresentation
import Foundation

public enum ASKTutorHistoryPresentationResolverError: Error, Sendable, Equatable {
    case unknownSession(sessionID: String)
    case unknownPracticeSet(practiceSetID: String)
    case unknownPracticeEvaluation(sessionID: String, practiceSetID: String)
    case practiceSetSessionMismatch(expectedSessionID: String, actualSessionID: String)
}

public struct ASKTutorHistoryPresentationResolver: Sendable {
    public init() {}

    public func resolveSession(
        sessionID: String,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorSessionHistoryPresentation {
        try await resolveSession(
            lookupSession(sessionID: sessionID, runtime: runtime),
            runtime: runtime
        )
    }

    public func resolvePracticeSet(
        practiceSetID: String,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorPracticeSetHistoryPresentation {
        let practiceSet = try await lookupPracticeSet(practiceSetID: practiceSetID, runtime: runtime)
        let session = try await lookupSession(sessionID: practiceSet.sessionID, runtime: runtime)
        return try await resolvePracticeSet(practiceSet, session: session, runtime: runtime)
    }

    public func resolvePracticeEvaluation(
        sessionID: String,
        practiceSetID: String,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorPracticeEvaluationHistoryPresentation {
        let evaluation = try await lookupPracticeEvaluation(
            sessionID: sessionID,
            practiceSetID: practiceSetID,
            runtime: runtime
        )

        let practiceSetPresentation = try await resolvePracticeSet(
            practiceSetID: practiceSetID,
            runtime: runtime
        )
        guard practiceSetPresentation.session.sessionID == evaluation.sessionID else {
            throw ASKTutorHistoryPresentationResolverError.practiceSetSessionMismatch(
                expectedSessionID: evaluation.sessionID,
                actualSessionID: practiceSetPresentation.session.sessionID
            )
        }

        return TutorPracticeEvaluationHistoryPresentation(
            evaluation: evaluation,
            practiceSetPresentation: practiceSetPresentation
        )
    }

    private func lookupSession(
        sessionID: String,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorSession {
        do {
            return try await runtime.tutor.session(TutorSessionLookupRequest(sessionID: sessionID))
        } catch let error as ASKTutorError {
            switch error {
            case .notFound:
                throw ASKTutorHistoryPresentationResolverError.unknownSession(sessionID: sessionID)
            default:
                throw error
            }
        }
    }

    private func lookupPracticeSet(
        practiceSetID: String,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorPracticeSet {
        do {
            return try await runtime.tutor.practiceSet(TutorPracticeSetLookupRequest(practiceSetID: practiceSetID))
        } catch let error as ASKTutorError {
            switch error {
            case .notFound:
                throw ASKTutorHistoryPresentationResolverError.unknownPracticeSet(practiceSetID: practiceSetID)
            default:
                throw error
            }
        }
    }

    private func lookupPracticeEvaluation(
        sessionID: String,
        practiceSetID: String,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorPracticeEvaluation {
        do {
            return try await runtime.tutor.practiceEvaluation(
                TutorPracticeEvaluationLookupRequest(sessionID: sessionID, practiceSetID: practiceSetID)
            )
        } catch let error as ASKTutorError {
            switch error {
            case .notFound:
                throw ASKTutorHistoryPresentationResolverError.unknownPracticeEvaluation(
                    sessionID: sessionID,
                    practiceSetID: practiceSetID
                )
            default:
                throw error
            }
        }
    }

    private func resolveSession(
        _ session: TutorSession,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorSessionHistoryPresentation {
        let linkResolver = ASKTutorHistoryProjectionLinkResolver(runtime: runtime)
        let scopePresentation = try await linkResolver.scopePresentation(
            sessionID: session.sessionID,
            scope: session.scope
        )

        var transcript: [TutorTranscriptEntryPresentation] = []
        transcript.reserveCapacity(session.transcript.count)
        for entry in session.transcript {
            transcript.append(
                TutorTranscriptEntryPresentation(
                    entry: entry,
                    citationLinks: try await linkResolver.citationLinks(entry.citations)
                )
            )
        }
        return TutorSessionHistoryPresentation(
            session: session,
            scopePresentation: scopePresentation,
            transcript: transcript
        )
    }

    private func resolvePracticeSet(
        _ practiceSet: TutorPracticeSet,
        session: TutorSession,
        runtime: ASKProductReadRuntime
    ) async throws -> TutorPracticeSetHistoryPresentation {
        let linkResolver = ASKTutorHistoryProjectionLinkResolver(runtime: runtime)
        let scopePresentation = try await linkResolver.scopePresentation(
            sessionID: session.sessionID,
            scope: session.scope
        )

        var questions: [TutorPracticeQuestionPresentation] = []
        questions.reserveCapacity(practiceSet.questions.count)
        for question in practiceSet.questions {
            questions.append(
                TutorPracticeQuestionPresentation(
                    question: question,
                    citationLinks: try await linkResolver.citationLinks(question.citations)
                )
            )
        }

        var evidence: [TutorEvidenceHitPresentation] = []
        evidence.reserveCapacity(practiceSet.evidence.count)
        for hit in practiceSet.evidence {
            evidence.append(
                TutorEvidenceHitPresentation(
                    evidenceHit: hit,
                    projectionLink: try await linkResolver.projectionLink(projectionSlug: hit.projectionSlug)
                )
            )
        }

        return TutorPracticeSetHistoryPresentation(
            practiceSet: practiceSet,
            session: session,
            scopePresentation: scopePresentation,
            questions: questions,
            evidence: evidence
        )
    }
}
