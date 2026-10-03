import Foundation

public struct TutorTranscriptEntry: Codable, Sendable, Equatable {
    public var entryID: String
    public var role: TutorTranscriptRole
    public var createdAt: String
    public var text: String
    public var citations: [TutorCitation]

    public init(
        entryID: String,
        role: TutorTranscriptRole,
        createdAt: String,
        text: String,
        citations: [TutorCitation] = []
    ) {
        self.entryID = entryID
        self.role = role
        self.createdAt = createdAt
        self.text = text
        self.citations = citations
    }
}

public struct TutorSession: Codable, Sendable, Equatable {
    public var sessionID: String
    public var learnerID: String
    public var title: String
    public var scope: TutorScope
    public var createdAt: String
    public var updatedAt: String
    public var transcript: [TutorTranscriptEntry]
    public var lastPracticeSetID: String?

    public init(
        sessionID: String,
        learnerID: String,
        title: String,
        scope: TutorScope,
        createdAt: String,
        updatedAt: String,
        transcript: [TutorTranscriptEntry] = [],
        lastPracticeSetID: String? = nil
    ) {
        self.sessionID = sessionID
        self.learnerID = learnerID
        self.title = title
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcript = transcript
        self.lastPracticeSetID = lastPracticeSetID
    }
}

public struct TutorNarrativeSection: Codable, Sendable, Equatable {
    public var heading: String
    public var body: String

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

public struct TutorReply: Codable, Sendable, Equatable {
    public var sessionID: String
    public var turnID: String
    public var intent: TutorIntent
    public var createdAt: String
    public var title: String
    public var summary: String
    public var sections: [TutorNarrativeSection]
    public var comprehensionChecks: [String]
    public var followUpPrompts: [String]
    public var citations: [TutorCitation]
    public var knowledgeGap: TutorKnowledgeGap?

    public init(
        sessionID: String,
        turnID: String,
        intent: TutorIntent,
        createdAt: String,
        title: String,
        summary: String,
        sections: [TutorNarrativeSection],
        comprehensionChecks: [String],
        followUpPrompts: [String],
        citations: [TutorCitation],
        knowledgeGap: TutorKnowledgeGap?
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.intent = intent
        self.createdAt = createdAt
        self.title = title
        self.summary = summary
        self.sections = sections
        self.comprehensionChecks = comprehensionChecks
        self.followUpPrompts = followUpPrompts
        self.citations = citations
        self.knowledgeGap = knowledgeGap
    }
}
