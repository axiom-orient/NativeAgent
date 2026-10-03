import Foundation

struct TutorNarrativeTurn: Sendable {
    let userEntry: TutorTranscriptEntry
    let tutorEntry: TutorTranscriptEntry
    let reply: TutorReply
}

enum TutorNarrativeComposer {
    static func compose(
        intent: TutorIntent,
        sessionID: String,
        prompt: String,
        requestedAt: String,
        grounding: TutorGrounding,
        draft: TutorNarrativeDraft,
        makeID: (TutorTranscriptRole) -> String
    ) -> TutorNarrativeTurn {
        let userEntry = TutorTranscriptEntry(
            entryID: makeID(.user),
            role: .user,
            createdAt: requestedAt,
            text: prompt
        )
        let tutorEntry = TutorTranscriptEntry(
            entryID: makeID(.tutor),
            role: .tutor,
            createdAt: requestedAt,
            text: replyText(from: draft),
            citations: grounding.citations
        )
        let reply = TutorReply(
            sessionID: sessionID,
            turnID: tutorEntry.entryID,
            intent: intent,
            createdAt: requestedAt,
            title: draft.title,
            summary: draft.summary,
            sections: draft.sections,
            comprehensionChecks: draft.comprehensionChecks,
            followUpPrompts: draft.followUpPrompts,
            citations: grounding.citations,
            knowledgeGap: grounding.knowledgeGap
        )
        return TutorNarrativeTurn(userEntry: userEntry, tutorEntry: tutorEntry, reply: reply)
    }

    private static func replyText(from draft: TutorNarrativeDraft) -> String {
        ([draft.summary] + draft.sections.map { "\($0.heading): \($0.body)" }).joined(separator: "\n\n")
    }
}
