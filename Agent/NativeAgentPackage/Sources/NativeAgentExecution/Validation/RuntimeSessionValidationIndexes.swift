import NativeAgentDomain

actor RuntimeSessionValidationIndexes {
    private var entries: [String: RuntimeSessionValidationIndex] = [:]

    func seed(_ index: RuntimeSessionValidationIndex) {
        entries[index.sessionID] = index
    }

    func remove(sessionID: String) {
        entries.removeValue(forKey: sessionID)
    }

    func prepare(
        snapshot: SessionSnapshot,
        delta: SessionPersistenceDelta?,
        validator: RuntimeResourceValidator
    ) throws -> RuntimeSessionValidationIndex {
        guard let delta,
              let previous = entries[snapshot.sessionID],
              previous.revision == delta.expectedRevision else {
            return try validator.validatedIndex(snapshot: snapshot)
        }
        return try validator.validatedIndex(
            snapshot: snapshot,
            delta: delta,
            previous: previous
        )
    }

    func commit(
        _ index: RuntimeSessionValidationIndex,
        status: SessionStatus
    ) {
        if status == .running {
            entries[index.sessionID] = index
        } else {
            // Waiting and terminal sessions are not advancing. Rebuild once
            // after a later explicit resume instead of retaining every session.
            entries.removeValue(forKey: index.sessionID)
        }
    }
}
