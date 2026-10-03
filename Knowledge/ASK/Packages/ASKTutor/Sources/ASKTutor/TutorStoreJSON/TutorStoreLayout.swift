import Foundation

package struct TutorStoreLayout: Sendable {
    package let rootURL: URL

    package var profilesDirectoryURL: URL {
        rootURL.appendingPathComponent("profiles", isDirectory: true)
    }

    package var sessionsDirectoryURL: URL {
        rootURL.appendingPathComponent("sessions", isDirectory: true)
    }

    package var practiceDirectoryURL: URL {
        rootURL.appendingPathComponent("practice", isDirectory: true)
    }

    package var plansDirectoryURL: URL {
        rootURL.appendingPathComponent("plans", isDirectory: true)
    }

    package func learnerURL(_ learnerID: String) throws -> URL {
        let learnerID = try TutorStorePathValidation.validatedPathSafeID(learnerID, field: "learnerID")
        return profilesDirectoryURL.appendingPathComponent("\(learnerID).json")
    }

    package func sessionURL(_ sessionID: String) throws -> URL {
        let sessionID = try TutorStorePathValidation.validatedPathSafeID(sessionID, field: "sessionID")
        return sessionsDirectoryURL.appendingPathComponent("\(sessionID).json")
    }

    package func sessionEvaluationsDirectoryURL(_ sessionID: String) throws -> URL {
        let sessionID = try TutorStorePathValidation.validatedPathSafeID(sessionID, field: "sessionID")
        return sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("evaluations", isDirectory: true)
    }

    package func practiceSetURL(_ practiceSetID: String) throws -> URL {
        let practiceSetID = try TutorStorePathValidation.validatedPathSafeID(practiceSetID, field: "practiceSetID")
        return practiceDirectoryURL.appendingPathComponent("\(practiceSetID).json")
    }

    package func practiceEvaluationURL(sessionID: String, practiceSetID: String) throws -> URL {
        let practiceSetID = try TutorStorePathValidation.validatedPathSafeID(practiceSetID, field: "practiceSetID")
        return try sessionEvaluationsDirectoryURL(sessionID)
            .appendingPathComponent("\(practiceSetID).json")
    }

    package func learnerPlansDirectoryURL(_ learnerID: String) throws -> URL {
        let learnerID = try TutorStorePathValidation.validatedPathSafeID(learnerID, field: "learnerID")
        return plansDirectoryURL.appendingPathComponent(learnerID, isDirectory: true)
    }

    package func studyPlanURL(learnerID: String, generatedAt: String) throws -> URL {
        try learnerPlansDirectoryURL(learnerID)
            .appendingPathComponent(safeFilename(generatedAt) + ".json")
    }

    package func safeFilename(_ value: String) throws -> String {
        try TutorStorePathValidation.ensureRFC3339(value, field: "generatedAt")
        return value.replacingOccurrences(of: ":", with: "-")
    }
}

enum TutorStorePathValidation {
    static func ensureRFC3339(_ value: String, field: String) throws {
        try TutorRuntimeValidation.ensureRFC3339(value, field: field)
    }

    static func ensurePathSafeID(_ value: String, field: String) throws {
        try TutorRuntimeValidation.ensurePathSafeID(value, field: field)
    }

    static func validatedPathSafeID(_ value: String, field: String) throws -> String {
        try TutorRuntimeValidation.validatedPathSafeID(value, field: field)
    }
}
