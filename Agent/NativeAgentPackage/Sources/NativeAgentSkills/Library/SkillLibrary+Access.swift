import NativeAgentDomain

extension SkillLibrary {
    func withLibraryAccess<Value>(
        kind: SkillLibraryAccessKind,
        operation: () async throws -> Value
    ) async throws -> Value {
        let claim = try await acquireLibraryAccess(kind: kind)
        let outcome: SkillLibraryAccessOperationOutcome<Value>
        do {
            outcome = .success(try await operation())
        } catch {
            outcome = .failure(error)
        }

        let releaseError: (any Error)?
        do {
            try await accessCoordinator.release(rootKey: accessRootKey, claim: claim)
            releaseError = nil
        } catch {
            releaseError = error
        }

        return try SkillLibraryAccessCompletionPolicy().resolve(
            outcome: outcome,
            releaseError: releaseError
        )
    }

    func acquireLibraryAccess(
        kind: SkillLibraryAccessKind
    ) async throws -> SkillLibraryAccessClaim {
        try await accessCoordinator.acquire(rootKey: accessRootKey, kind: kind)
    }
}
