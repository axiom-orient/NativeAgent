import NativeAgentDomain

extension SkillLibrary {
    public func saveSecret(_ secret: String, for skillName: String) async throws {
        try await withLibraryAccess(kind: .secretMutation) {
            try await secretStore.writeSecret(secret, for: skillName)
        }
    }

    public func deleteSecret(for skillName: String) async throws {
        try await withLibraryAccess(kind: .secretMutation) {
            try await secretStore.deleteSecret(for: skillName)
        }
    }

    public func readSecret(for skillName: String) async throws -> String? {
        try await withLibraryAccess(kind: .read) {
            try await secretStore.readSecret(for: skillName)
        }
    }
}
