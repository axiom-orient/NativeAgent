import Foundation

public struct TutorSessionContext: Codable, Sendable, Equatable {
    public var sessionID: String
    public var title: String
    public var scope: TutorScope
    public var recentTranscript: [TutorTranscriptEntry]

    public init(sessionID: String, title: String, scope: TutorScope, recentTranscript: [TutorTranscriptEntry]) {
        self.sessionID = sessionID
        self.title = title
        self.scope = scope
        self.recentTranscript = recentTranscript
    }
}

public struct TutorNarrativeDraft: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var sections: [TutorNarrativeSection]
    public var comprehensionChecks: [String]
    public var followUpPrompts: [String]

    public init(
        title: String,
        summary: String,
        sections: [TutorNarrativeSection],
        comprehensionChecks: [String],
        followUpPrompts: [String]
    ) {
        self.title = title
        self.summary = summary
        self.sections = sections
        self.comprehensionChecks = comprehensionChecks
        self.followUpPrompts = followUpPrompts
    }
}

public struct TutorExplainModelRequest: Codable, Sendable, Equatable {
    public var learner: LearnerProfile
    public var session: TutorSessionContext
    public var grounding: TutorGrounding
    public var projection: TutorProjectionSnapshot?
    public var responseStyle: TutorResponseStyle

    public init(
        learner: LearnerProfile,
        session: TutorSessionContext,
        grounding: TutorGrounding,
        projection: TutorProjectionSnapshot?,
        responseStyle: TutorResponseStyle
    ) {
        self.learner = learner
        self.session = session
        self.grounding = grounding
        self.projection = projection
        self.responseStyle = responseStyle
    }
}
