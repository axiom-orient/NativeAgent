import Foundation

struct TutorPracticeMaterialization: Sendable {
    let practiceSet: TutorPracticeSet
    let sessionTranscriptEntry: TutorTranscriptEntry
}

enum TutorPracticeSetMaterializer {
    static func materialize(
        sessionID: String,
        requestedAt: String,
        draft: TutorPracticeDraft,
        evidence: [TutorEvidenceHit],
        maxCitations: Int,
        makeID: (String) -> String,
        makePracticeSetID: () -> String
    ) -> TutorPracticeMaterialization {
        let citations = evidence
            .prefix(maxCitations)
            .map { TutorCitation(docID: $0.docID, title: $0.title, projectionSlug: $0.projectionSlug) }
        let practiceSetID = makePracticeSetID()
        let questions = draft.questions.enumerated().map { index, question in
            TutorPracticeQuestion(
                questionID: "q\(index + 1)",
                prompt: question.prompt,
                idealAnswer: question.idealAnswer,
                hints: question.hints,
                conceptIDs: question.conceptIDs,
                citations: citations
            )
        }
        let practiceSet = TutorPracticeSet(
            practiceSetID: practiceSetID,
            sessionID: sessionID,
            topic: draft.topic,
            createdAt: requestedAt,
            recap: draft.recap,
            questions: questions,
            evidence: evidence
        )
        let transcriptEntry = TutorTranscriptEntry(
            entryID: makeID("transcript"),
            role: .system,
            createdAt: requestedAt,
            text: "Generated practice set `\(practiceSetID)` for topic: \(draft.topic)."
        )
        return TutorPracticeMaterialization(practiceSet: practiceSet, sessionTranscriptEntry: transcriptEntry)
    }
}

struct TutorPracticeGradingOutcome: Sendable {
    let learner: LearnerProfile
    let evaluation: TutorPracticeEvaluation
}

enum TutorPracticeEvaluationReducer {
    static func reduce(
        learner: LearnerProfile,
        session: TutorSession,
        practiceSet: TutorPracticeSet,
        draft: TutorGradeDraft,
        configuration: TutorConfiguration,
        requestedAt: String
    ) throws -> TutorPracticeGradingOutcome {
        var updatedLearner = learner
        let scheduler = TutorReviewScheduler(configuration: configuration)
        var updatedStates: [TutorConceptState] = []

        for item in draft.itemResults {
            for conceptID in resolvedConceptIDs(for: item, practiceSet: practiceSet) {
                let existing = updatedLearner.conceptStates[conceptID]
                let label = existing?.label ?? conceptID
                let state = try scheduler.updateConcept(
                    existing,
                    conceptID: conceptID,
                    label: label,
                    score: item.score,
                    reviewedAt: requestedAt
                )
                updatedLearner.conceptStates[conceptID] = state
                updatedStates.append(state)
            }
        }

        updatedLearner.updatedAt = requestedAt
        let evaluation = TutorPracticeEvaluation(
            sessionID: session.sessionID,
            practiceSetID: practiceSet.practiceSetID,
            createdAt: requestedAt,
            summary: draft.summary,
            overallScore: draft.overallScore,
            itemResults: draft.itemResults.map(makeItemResult),
            updatedConceptStates: updatedStates.sorted { $0.conceptID < $1.conceptID },
            recommendedFocusTopics: draft.recommendedFocusTopics
        )
        return TutorPracticeGradingOutcome(learner: updatedLearner, evaluation: evaluation)
    }

    private static func resolvedConceptIDs(for item: TutorGradeDraftItem, practiceSet: TutorPracticeSet) -> [String] {
        guard item.conceptIDs.isEmpty else {
            return item.conceptIDs
        }
        return practiceSet.questions.first(where: { $0.questionID == item.questionID })?.conceptIDs ?? []
    }

    private static func makeItemResult(_ item: TutorGradeDraftItem) -> TutorPracticeItemResult {
        TutorPracticeItemResult(
            questionID: item.questionID,
            score: item.score,
            verdict: item.verdict,
            feedback: item.feedback,
            expectedPoints: item.expectedPoints,
            conceptIDs: item.conceptIDs
        )
    }
}
