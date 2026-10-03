import Foundation
import KnowledgeCore

package enum TutorRuntimeValidation {
    package static func ensureRFC3339(_ value: String, field: String) throws {
        guard TutorTime.parse(value) != nil else {
            throw ASKTutorError.invalidInput("\(field) must be RFC3339")
        }
    }

    package static func ensurePathSafeID(_ value: String, field: String) throws {
        _ = try validatedPathSafeID(value, field: field)
    }

    package static func validatedPathSafeID(_ value: String, field: String) throws -> String {
        guard value.isEmpty == false else {
            throw ASKTutorError.invalidInput("\(field) must not be empty")
        }
        let isValid = value.unicodeScalars.allSatisfy { scalar in
            let character = Character(scalar)
            return scalar.isASCII && (character.isLowercase || character.isNumber || character == "-" || character == "_")
        }
        guard isValid else {
            throw ASKTutorError.invalidInput("\(field) must contain only [a-z0-9_-]")
        }
        return value
    }
}

enum TutorIdentifiers {
    static func sessionID(learnerID: String, title: String, scope: TutorScope, requestedAt: String) -> String {
        stableID(prefix: "session", parts: [
            learnerID,
            title,
            scopeKey(scope),
            requestedAt,
        ])
    }

    static func practiceSetID(sessionID: String, requestedAt: String, topic: String) -> String {
        stableID(prefix: "practice", parts: [
            sessionID,
            requestedAt,
            topic,
        ])
    }

    static func transcriptEntryID(
        sessionID: String,
        role: TutorTranscriptRole,
        requestedAt: String,
        purpose: String,
        ordinal: Int
    ) -> String {
        stableID(prefix: "turn", parts: [
            sessionID,
            role.rawValue,
            requestedAt,
            purpose,
            String(ordinal),
        ])
    }

    static func scopeKey(_ scope: TutorScope) -> String {
        switch scope {
        case .global:
            return "global"
        case .projection(let slug):
            return "projection:\(slug)"
        case .subject(let kind, let id):
            return "subject:\(kind):\(id)"
        }
    }
}

enum TutorSessionProjection {
    static func context(from session: TutorSession, recentTranscriptLimit: Int) -> TutorSessionContext {
        let recent = Array(session.transcript.suffix(recentTranscriptLimit))
        return TutorSessionContext(
            sessionID: session.sessionID,
            title: session.title,
            scope: session.scope,
            recentTranscript: recent
        )
    }
}

enum TutorStudyPlanning {
    static func dueConcepts(from conceptStates: [String: TutorConceptState], requestedAt: String) -> [TutorConceptState] {
        guard let targetDate = TutorTime.parse(requestedAt) else {
            return []
        }
        return conceptStates.values
            .filter { state in
                guard let due = state.nextReviewAt, let dueDate = TutorTime.parse(due) else {
                    return false
                }
                return dueDate <= targetDate
            }
            .sorted { $0.conceptID < $1.conceptID }
    }
}


enum TutorRequestValidation {
    static func practiceQuestionCount(_ requested: Int?, defaultValue: Int) throws -> Int {
        let resolved = requested ?? defaultValue
        guard resolved > 0 else {
            throw ASKTutorError.invalidInput("questionCount must be greater than zero")
        }
        return resolved
    }
}

enum TutorGradeValidation {
    static func ensurePracticeBelongsToSession(_ practiceSet: TutorPracticeSet, sessionID: String) throws {
        guard practiceSet.sessionID == sessionID else {
            throw ASKTutorError.invalidInput("practice set does not belong to session")
        }
    }
}
