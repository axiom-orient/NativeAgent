import Foundation

struct Scope {
    var workspaceID: String
    var profileID: String
    var userID: String
    /// Namespace is the retrieval boundary. It is deliberately independent
    /// from the source session so default recall can span sessions.
    var namespace: String
    var sessionKey: String

    init(
        workspaceID: String,
        profileID: String,
        userID: String,
        namespace: String = "",
        sessionKey: String = ""
    ) {
        self.workspaceID = workspaceID
        self.profileID = profileID
        self.userID = userID
        self.namespace = namespace
        self.sessionKey = sessionKey
    }

    func validate(requireSession: Bool = false) throws {
        if workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.validation("missing_identity", "workspace_id is required")
        }
        if profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.validation("missing_identity", "profile_id is required")
        }
        if userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.validation("missing_identity", "user_id is required")
        }
        if namespace.utf8.count > 128 {
            throw AppError.validation("invalid_namespace", "namespace exceeds 128 UTF-8 bytes")
        }
        if requireSession && sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.validation("missing_identity", "session_key is required")
        }
    }
}
