import Foundation

extension Store {
    func consolidationInput(scope: Scope, sessionID: String) throws -> (checkpoint: MemoryCheckpoint, events: [MemoryEvent], generation: Int64)? {
        var result: (MemoryCheckpoint, [MemoryEvent], Int64)?
        try inTx {
            guard let checkpoint = try checkpoint(scope: scope, sourceSessionID: sessionID) else { return }
            let events = try pendingEvents(scope: scope, sourceSessionID: sessionID,
                afterRowID: checkpoint.consolidatedRowID, limit: 32)
            result = (checkpoint, events, try scopeGeneration(scope))
        }
        return result
    }

    func scopeGeneration(_ scope: Scope) throws -> Int64 {
        try db.query("SELECT generation FROM memory_scope_generation WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?",
            scopeParameters(scope)).first.map { try $0.int(0) } ?? 0
    }

    func requireGeneration(_ expected: Int64, scope: Scope, code: String) throws {
        guard try scopeGeneration(scope) == expected else {
            throw AppError.storage(code, "memory scope was reset or forgotten while the operation was running")
        }
    }

    /// Called inside the same transaction that removes the projection.
    func advanceScopeGeneration(_ scope: Scope) throws {
        try db.exec("""
            INSERT INTO memory_scope_generation(workspace_id,profile_id,user_id,namespace,generation)
            VALUES(?,?,?,?,1) ON CONFLICT(workspace_id,profile_id,user_id,namespace)
            DO UPDATE SET generation=generation+1
            """, scopeParameters(scope))
    }

    /// The observed prefix covers even messages that capture admission filtered.
    /// IDs additionally cover direct capture and same-ID transcript forks.
    func rememberForgottenInputs(_ scope: Scope) throws {
        let parameters = scopeParameters(scope)
        try db.exec("""
            INSERT INTO memory_forgotten_session(workspace_id,profile_id,user_id,namespace,source_session_id,message_count)
            SELECT workspace_id,profile_id,user_id,namespace,source_session_id,message_count FROM memory_checkpoint
            WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
            ON CONFLICT(workspace_id,profile_id,user_id,namespace,source_session_id)
            DO UPDATE SET message_count=MAX(message_count,excluded.message_count)
            """, parameters)
        try db.exec("""
            INSERT OR IGNORE INTO memory_forgotten_message(workspace_id,profile_id,user_id,namespace,source_message_id)
            SELECT workspace_id,profile_id,user_id,namespace,source_message_id FROM memory_event
            WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
            """, parameters)
    }

    /// Must run in the event insertion transaction, including direct capture.
    func isForgotten(_ event: MemoryEvent) throws -> Bool {
        let parameters: [SQLValue] = [.text(event.workspaceID), .text(event.profileID), .text(event.userID), .text(event.namespace)]
        if try db.query("SELECT 1 FROM memory_forgotten_message WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=? AND source_message_id=?",
            parameters + [.text(event.sourceMessageID)]).isEmpty == false { return true }
        if let index = event.sourceIndex,
           let row = try db.query("SELECT message_count FROM memory_forgotten_session WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=? AND source_session_id=?",
                parameters + [.text(event.sourceSessionID)]).first {
            return Int64(index) < (try row.int(0))
        }
        return false
    }

    private func scopeParameters(_ scope: Scope) -> [SQLValue] {
        [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace)]
    }
}
