import Foundation

private enum MemoryStoreLimits {
    static let maximumConsolidationPageSize = 32
}

extension Store {
    func capabilities() throws -> AgentMemoryCapabilities {
        capabilitySnapshot
    }

    func checkpoint(scope: Scope, sourceSessionID: String) throws -> MemoryCheckpoint? {
        let rows = try db.query(
            """
            SELECT workspace_id,profile_id,user_id,namespace,source_session_id,
                   message_count,agent_revision,consolidated_rowid,
                   last_source_message_id,last_source_content_hash,last_source_role,
                   last_source_occurred_at_ms
            FROM memory_checkpoint
            WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=? AND source_session_id=?
            """,
            [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID),
             .text(scope.namespace), .text(sourceSessionID)]
        )
        guard let row = rows.first else { return nil }
        return try memoryCheckpoint(row)
    }

    func insertEvents(_ events: [MemoryEvent]) throws -> (inserted: Int, rowIDs: [Int64]) {
        guard events.isEmpty == false else { return (0, []) }
        var inserted = 0
        var rowIDs: [Int64] = []
        try inTx {
            (inserted, rowIDs) = try insertEventsWithoutTransaction(events)
        }
        return (inserted, rowIDs)
    }

    private func insertEventsWithoutTransaction(_ events: [MemoryEvent]) throws -> (inserted: Int, rowIDs: [Int64]) {
        var inserted = 0
        var rowIDs: [Int64] = []
        for event in events {
                if try isForgotten(event) { continue }
                guard event.id.isEmpty == false, event.sourceMessageID.isEmpty == false else {
                    throw AppError.validation("invalid_event_identity", "memory event identity is empty")
                }
                if let existing = try db.query(
                    "SELECT rowid,role,content,content_hash,source_session_id,source_index FROM memory_event WHERE id=?",
                    [.text(event.id)]
                ).first {
                    let oldHash = try existing.text(3)
                    guard oldHash == event.contentHash,
                          try existing.text(1) == event.role,
                          try existing.text(2) == event.content else {
                        throw AppError.storage(
                            "transcript_rewrite",
                            "source message identity was reused with different content or role"
                        )
                    }
                    if try existing.text(4) == event.sourceSessionID {
                        let storedIndex = try existing.optInt(5).map(Int.init)
                        guard storedIndex == event.sourceIndex else {
                            throw AppError.storage(
                                "transcript_rewrite",
                                "source message moved to a different transcript position"
                            )
                        }
                    }
                    rowIDs.append(try existing.int(0))
                    continue
                }
                if let existing = try db.query(
                    """
                    SELECT rowid,role,content,content_hash,source_session_id,source_index FROM memory_event
                    WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
                      AND source_message_id=?
                    """,
                    [.text(event.workspaceID), .text(event.profileID), .text(event.userID),
                     .text(event.namespace), .text(event.sourceMessageID)]
                ).first {
                    guard try existing.text(1) == event.role,
                          try existing.text(2) == event.content,
                          try existing.text(3) == event.contentHash else {
                        throw AppError.storage(
                            "transcript_rewrite",
                            "source message content changed under an existing scope"
                        )
                    }
                    if try existing.text(4) == event.sourceSessionID {
                        let storedIndex = try existing.optInt(5).map(Int.init)
                        guard storedIndex == event.sourceIndex else {
                            throw AppError.storage(
                                "transcript_rewrite",
                                "source message moved to a different transcript position"
                            )
                        }
                    }
                    rowIDs.append(try existing.int(0))
                    continue
                }
                if let sourceIndex = event.sourceIndex,
                   let existing = try db.query(
                    """
                    SELECT source_message_id,content_hash FROM memory_event
                    WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
                      AND source_session_id=? AND source_index=?
                    """,
                    [.text(event.workspaceID), .text(event.profileID), .text(event.userID),
                     .text(event.namespace), .text(event.sourceSessionID), .int(Int64(sourceIndex))]
                   ).first {
                    let messageID = try existing.text(0)
                    let hash = try existing.text(1)
                    guard messageID == event.sourceMessageID, hash == event.contentHash else {
                    throw AppError.storage(
                        "transcript_rewrite",
                        "transcript ordering or content changed at an existing position"
                    )
                    }
                }
                try db.exec(
                    """
                    INSERT INTO memory_event(
                        id,workspace_id,profile_id,user_id,namespace,source_session_id,
                        source_message_id,source_index,role,content,occurred_at_ms,content_hash,metadata_json
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    [.text(event.id), .text(event.workspaceID), .text(event.profileID),
                     .text(event.userID), .text(event.namespace), .text(event.sourceSessionID),
                     .text(event.sourceMessageID), event.sourceIndex.map { .int(Int64($0)) } ?? .null,
                     .text(event.role), .text(event.content),
                     .int(event.occurredAtMS), .text(event.contentHash), .text(event.metadataJSON)]
                )
                inserted += 1
                let rowID = try db.query(
                    "SELECT rowid FROM memory_event WHERE id=?", [.text(event.id)]
                ).first.map { try $0.int(0) }
                guard let rowID else {
                    throw AppError.storage("event_row_missing", "inserted event row cannot be read")
                }
                rowIDs.append(rowID)
        }
        return (inserted, rowIDs)
    }

    func syncPlan(
        scope: Scope,
        sourceSessionID: String,
        journal: AgentMemoryJournalState,
        lastMessage: AgentMemoryIncomingMessage?,
        expectedGeneration: Int64 = 0
    ) throws -> AgentMemorySyncPlan {
        var result: AgentMemorySyncPlan?
        try inTx {
            try requireGeneration(expectedGeneration, scope: scope, code: "stale_sync_result")
            result = try makeSyncPlan(scope: scope, sourceSessionID: sourceSessionID,
                journal: journal, lastMessage: lastMessage)
        }
        guard let result else { throw AppError.internalError("sync_plan_missing", "sync plan was not produced") }
        return result
    }

    private func makeSyncPlan(
        scope: Scope,
        sourceSessionID: String,
        journal: AgentMemoryJournalState,
        lastMessage: AgentMemoryIncomingMessage?
    ) throws -> AgentMemorySyncPlan {
        guard sourceSessionID.isEmpty == false, journal.messageCount >= 0, journal.revision >= 0 else {
            throw AppError.validation("invalid_transcript_journal", "transcript journal is invalid")
        }
        guard let current = try checkpoint(scope: scope, sourceSessionID: sourceSessionID) else {
            return AgentMemorySyncPlan(offset: 0, messageCount: journal.messageCount,
                                       revision: journal.revision, noOp: journal.messageCount == 0)
        }
        guard journal.messageCount >= current.messageCount else {
            throw AppError.storage(
                "transcript_truncated",
                "transcript message count moved backwards"
            )
        }
        guard journal.revision >= current.agentRevision else {
            throw AppError.storage(
                "transcript_revision_regressed",
                "transcript revision moved backwards"
            )
        }
        if current.messageCount > 0 {
            guard let lastMessage else {
                throw AppError.storage("transcript_probe_missing", "cannot verify transcript tail")
            }
            guard current.lastSourceMessageID == lastMessage.id,
                  current.lastSourceContentHash == lastMessage.rawContentHash,
                  current.lastSourceRole == lastMessage.role,
                  current.lastSourceOccurredAtMS == lastMessage.occurredAtMS else {
                throw AppError.storage(
                    "transcript_rewrite",
                    "committed transcript tail changed since the last sync"
                )
            }
        }
        if current.messageCount == journal.messageCount,
           (journal.revision == current.agentRevision || journal.messageCount == 0) {
            return AgentMemorySyncPlan(offset: current.messageCount, messageCount: journal.messageCount,
                                       revision: journal.revision, noOp: true)
        }
        // A revision change with an unchanged count requires a complete
        // ordered re-read. The source index check in insertEventsWithoutTransaction
        // rejects middle-message rewrites and reordering instead of silently
        // treating the old projection as current.
        let offset = current.messageCount == journal.messageCount ? 0 : current.messageCount
        return AgentMemorySyncPlan(offset: offset, messageCount: journal.messageCount,
                                   revision: journal.revision, noOp: false)
    }

    func applySyncPage(
        scope: Scope,
        sourceSessionID: String,
        journal: AgentMemoryJournalState,
        page: AgentMemoryIncomingPage,
        expectedOffset: Int,
        expectedGeneration: Int64 = 0
    ) throws -> AgentMemorySyncResult {
        guard page.offset == expectedOffset else {
            throw AppError.storage("transcript_page_gap", "transcript page offset is not contiguous")
        }
        guard page.totalCount == journal.messageCount else {
            throw AppError.storage(
                "transcript_changed",
                "transcript count changed while pages were being fetched"
            )
        }
        guard expectedOffset >= 0, expectedOffset < journal.messageCount,
              page.messages.isEmpty == false,
              page.messages.count <= 100 else {
            throw AppError.storage("invalid_transcript_page", "transcript page is outside the journal")
        }
        let (pageEnd, pageEndOverflow) = expectedOffset.addingReportingOverflow(page.messages.count)
        guard !pageEndOverflow, pageEnd <= journal.messageCount else {
            throw AppError.storage("invalid_transcript_page", "transcript page is outside the journal")
        }
        var seen: Set<String> = []
        var events: [MemoryEvent] = []
        events.reserveCapacity(page.messages.count)
        for incoming in page.messages {
            guard incoming.id.isEmpty == false, seen.insert(incoming.id).inserted else {
                throw AppError.storage("duplicate_transcript_message", "transcript page repeats a message id")
            }
            guard incoming.role == "system" || incoming.role == "user" || incoming.role == "assistant" || incoming.role == "tool" else {
                throw AppError.validation("unsupported_message_role", "only system, user, assistant, and tool transcript messages are supported")
            }
            if let event = try makeMemoryEvent(
                scope: scope,
                sourceSessionID: sourceSessionID,
                message: incoming
            ) {
                events.append(event)
            }
        }
        let complete = pageEnd == journal.messageCount
        guard let last = page.messages.last else {
            throw AppError.storage("invalid_transcript_page", "transcript page has no messages")
        }
        var insertion = (inserted: 0, rowIDs: [Int64]())
        var committedMessageCount = 0
        var committedRevision: Int64 = 0
        try inTx {
            try requireGeneration(expectedGeneration, scope: scope, code: "stale_sync_result")
            let current = try checkpoint(scope: scope, sourceSessionID: sourceSessionID)
            let replayingCommittedPrefix: Bool
            if let current,
               current.messageCount == journal.messageCount,
               expectedOffset < current.messageCount {
                guard journal.revision > current.agentRevision else {
                    throw AppError.storage(
                        "stale_sync_result",
                        "transcript replay no longer targets the authoritative checkpoint"
                    )
                }
                replayingCommittedPrefix = true
            } else {
                guard (current == nil && expectedOffset == 0) || current?.messageCount == expectedOffset else {
                    throw AppError.storage(
                        "stale_sync_result",
                        "transcript page no longer starts at the authoritative checkpoint"
                    )
                }
                if let current, journal.revision < current.agentRevision {
                    throw AppError.storage(
                        "stale_sync_result",
                        "transcript revision is older than the authoritative checkpoint"
                    )
                }
                replayingCommittedPrefix = false
            }

            insertion = try insertEventsWithoutTransaction(events)

            if replayingCommittedPrefix && complete == false {
                guard let current else {
                    throw AppError.internalError("checkpoint_missing", "replay lost its authoritative checkpoint")
                }
                committedMessageCount = current.messageCount
                committedRevision = current.agentRevision
                return
            }

            let messageCount = replayingCommittedPrefix
                ? (current?.messageCount ?? journal.messageCount)
                : pageEnd
            let revision = complete ? journal.revision : (current?.agentRevision ?? 0)
            let next = MemoryCheckpoint(
                workspaceID: scope.workspaceID,
                profileID: scope.profileID,
                userID: scope.userID,
                namespace: scope.namespace,
                sourceSessionID: sourceSessionID,
                messageCount: messageCount,
                agentRevision: revision,
                consolidatedRowID: current?.consolidatedRowID ?? 0,
                lastSourceMessageID: last.id,
                lastSourceContentHash: last.rawContentHash,
                lastSourceRole: last.role,
                lastSourceOccurredAtMS: last.occurredAtMS
            )
            try upsertCheckpoint(next)
            committedMessageCount = next.messageCount
            committedRevision = next.agentRevision
        }
        return AgentMemorySyncResult(
            scannedMessages: page.messages.count,
            insertedEvents: insertion.inserted,
            messageCount: committedMessageCount,
            revision: committedRevision
        )
    }

    func upsertCheckpoint(_ checkpoint: MemoryCheckpoint) throws {
        try db.exec(
            """
            INSERT INTO memory_checkpoint(
                workspace_id,profile_id,user_id,namespace,source_session_id,
                message_count,agent_revision,consolidated_rowid,
                last_source_message_id,last_source_content_hash,last_source_role,last_source_occurred_at_ms
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id,profile_id,user_id,namespace,source_session_id)
            DO UPDATE SET message_count=excluded.message_count,
                          agent_revision=excluded.agent_revision,
                          consolidated_rowid=excluded.consolidated_rowid,
                          last_source_message_id=excluded.last_source_message_id,
                          last_source_content_hash=excluded.last_source_content_hash,
                          last_source_role=excluded.last_source_role,
                          last_source_occurred_at_ms=excluded.last_source_occurred_at_ms
            """,
            [.text(checkpoint.workspaceID), .text(checkpoint.profileID), .text(checkpoint.userID),
             .text(checkpoint.namespace), .text(checkpoint.sourceSessionID), .int(Int64(checkpoint.messageCount)),
             .int(checkpoint.agentRevision), .int(checkpoint.consolidatedRowID),
             .text(checkpoint.lastSourceMessageID), .text(checkpoint.lastSourceContentHash),
             .text(checkpoint.lastSourceRole), .int(checkpoint.lastSourceOccurredAtMS)]
        )
    }

    func insertDirectEvents(_ events: [MemoryEvent]) throws -> Int {
        try insertEvents(events).inserted
    }

    func pendingEvents(
        scope: Scope,
        sourceSessionID: String,
        afterRowID: Int64,
        limit: Int = MemoryStoreLimits.maximumConsolidationPageSize
    ) throws -> [MemoryEvent] {
        guard (1...MemoryStoreLimits.maximumConsolidationPageSize).contains(limit) else {
            throw AppError.validation(
                "invalid_consolidation_limit",
                "consolidation page limit must be 1...\(MemoryStoreLimits.maximumConsolidationPageSize)"
            )
        }
        let rows = try db.query(
            """
            SELECT rowid,id,workspace_id,profile_id,user_id,namespace,source_session_id,
                   source_message_id,source_index,role,content,occurred_at_ms,content_hash,metadata_json
            FROM memory_event
            WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
              AND source_session_id=? AND rowid>?
            ORDER BY rowid ASC LIMIT ?
            """,
            [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace),
             .text(sourceSessionID), .int(afterRowID), .int(Int64(limit))]
        )
        return try rows.map(memoryEvent)
    }

    func upsertRecord(_ record: MemoryRecord) throws -> (record: MemoryRecord, inserted: Bool) {
        let existing: [SQLRow]
        if let slot = record.slotKey {
            existing = try db.query(
                """
                SELECT rowid,id,workspace_id,profile_id,user_id,namespace,source_session_id,
                       kind,slot_key,content,valid_from_ms,created_at_ms,content_hash
                FROM memory_record
                WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
                  AND kind=? AND slot_key=? AND content_hash=?
                """,
                [.text(record.workspaceID), .text(record.profileID), .text(record.userID), .text(record.namespace),
                 .text(record.kind.rawValue), .text(slot), .text(record.contentHash)]
            )
        } else {
            existing = try db.query(
                """
                SELECT rowid,id,workspace_id,profile_id,user_id,namespace,source_session_id,
                       kind,slot_key,content,valid_from_ms,created_at_ms,content_hash
                FROM memory_record
                WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?
                  AND kind=? AND slot_key IS NULL AND content_hash=?
                """,
                [.text(record.workspaceID), .text(record.profileID), .text(record.userID), .text(record.namespace),
                 .text(record.kind.rawValue), .text(record.contentHash)]
            )
        }
        if let row = existing.first { return (try memoryRecord(row), false) }
        try db.exec(
            """
            INSERT INTO memory_record(
                id,workspace_id,profile_id,user_id,namespace,source_session_id,kind,slot_key,
                content,valid_from_ms,created_at_ms,content_hash
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(record.id), .text(record.workspaceID), .text(record.profileID), .text(record.userID),
             .text(record.namespace), .text(record.sourceSessionID), .text(record.kind.rawValue),
             record.slotKey.map(SQLValue.text) ?? .null, .text(record.content),
             record.validFromMS.map(SQLValue.int) ?? .null, .int(record.createdAtMS), .text(record.contentHash)]
        )
        let row = try db.query(
            "SELECT rowid,id,workspace_id,profile_id,user_id,namespace,source_session_id,kind,slot_key,content,valid_from_ms,created_at_ms,content_hash FROM memory_record WHERE id=?",
            [.text(record.id)]
        ).first
        guard let row else { throw AppError.storage("record_row_missing", "inserted record row cannot be read") }
        return (try memoryRecord(row), true)
    }

    @discardableResult
    func addEvidence(_ evidence: MemoryEvidence) throws -> Bool {
        try db.exec(
            "INSERT OR IGNORE INTO memory_evidence(record_id,event_id,quote) VALUES(?,?,?)",
            [.text(evidence.recordID), .text(evidence.eventID), .text(evidence.quote)]
        )
        return db.changes() == 1
    }

    @discardableResult
    func addRelation(_ relation: MemoryRelation) throws -> Bool {
        try db.exec(
            "INSERT OR IGNORE INTO memory_relation(from_record_id,relation,to_record_id) VALUES(?,?,?)",
            [.text(relation.fromRecordID), .text(relation.relation.rawValue), .text(relation.toRecordID)]
        )
        return db.changes() == 1
    }

    func activeRecord(scope: Scope, kind: ProjectionRecordKind, slotKey: String) throws -> MemoryRecord? {
        let rows = try db.query(
            """
            SELECT r.rowid,r.id,r.workspace_id,r.profile_id,r.user_id,r.namespace,r.source_session_id,
                   r.kind,r.slot_key,r.content,r.valid_from_ms,r.created_at_ms,r.content_hash
            FROM memory_record r
            WHERE r.workspace_id=? AND r.profile_id=? AND r.user_id=? AND r.namespace=?
              AND r.kind=? AND r.slot_key=?
              AND NOT EXISTS (SELECT 1 FROM memory_relation x WHERE x.relation='supersedes' AND x.to_record_id=r.id)
            ORDER BY COALESCE(r.valid_from_ms,r.created_at_ms) DESC,r.id ASC LIMIT 1
            """,
            [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace), .text(kind.rawValue), .text(slotKey)]
        )
        return try rows.first.map(memoryRecord)
    }

    func activeInstructions(
        scope: Scope,
        excludingMessageIDs: Set<String> = [],
        limit: Int = 3
    ) throws -> [MemorySearchHit] {
        guard (1...3).contains(limit) else {
            throw AppError.validation("invalid_instruction_limit", "active instruction limit must be 1...3")
        }
        var conditions = [
            "r.workspace_id=?", "r.profile_id=?", "r.user_id=?", "r.namespace=?",
            "r.kind=?",
            "NOT EXISTS (SELECT 1 FROM memory_relation x WHERE x.relation='supersedes' AND x.to_record_id=r.id)"
        ]
        var params: [SQLValue] = [
            .text(scope.workspaceID), .text(scope.profileID), .text(scope.userID),
            .text(scope.namespace), .text(ProjectionRecordKind.instruction.rawValue)
        ]
        appendEvidenceExclusion(
            conditions: &conditions,
            params: &params,
            recordAlias: "r",
            excludingMessageIDs: excludingMessageIDs
        )
        let rows = try db.query(
            """
            SELECT r.rowid,r.id,r.kind,r.content,r.source_session_id,r.slot_key,r.created_at_ms,
                   COALESCE(r.valid_from_ms,r.created_at_ms),0.0
            FROM memory_record r
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY COALESCE(r.valid_from_ms,r.created_at_ms) DESC,r.id ASC LIMIT ?
            """,
            params + [.int(Int64(limit))]
        )
        return try rows.map { row in
            let recordID = try row.text(1)
            return MemorySearchHit(
                id: recordID, layer: "record", kind: try row.text(2), role: "",
                content: try row.text(3), score: 0.0, sourceSessionID: try row.text(4),
                sourceMessageIDs: try evidenceSourceMessageIDs(recordID: recordID),
                slotKey: try row.optText(5)
            )
        }
    }

    func searchRecords(
        scope: Scope,
        query: ProjectionSearchQuery,
        excludingMessageIDs: Set<String> = []
    ) throws -> [MemorySearchHit] {
        var conditions = [
            "r.workspace_id=?", "r.profile_id=?", "r.user_id=?", "r.namespace=?"
        ]
        var params: [SQLValue] = [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace)]
        if query.historical == false {
            conditions.append("NOT EXISTS (SELECT 1 FROM memory_relation x WHERE x.relation='supersedes' AND x.to_record_id=r.id)")
        }
        appendEvidenceExclusion(
            conditions: &conditions,
            params: &params,
            recordAlias: "r",
            excludingMessageIDs: excludingMessageIDs
        )
        if query.kinds.isEmpty == false {
            let sorted = query.kinds.map(\.rawValue).sorted()
            conditions.append("r.kind IN (" + Array(repeating: "?", count: sorted.count).joined(separator: ",") + ")")
            params.append(contentsOf: sorted.map(SQLValue.text))
        }
        if let fromMS = query.fromMS { conditions.append("COALESCE(r.valid_from_ms,r.created_at_ms)>=?"); params.append(.int(fromMS)) }
        if let toMS = query.toMS { conditions.append("COALESCE(r.valid_from_ms,r.created_at_ms)<=?"); params.append(.int(toMS)) }
        let terms = ftsQuery(query.query)
        // The public engine currently admits at most eight results, but this
        // store boundary is also used by package-internal callers. Clamp before
        // doubling so an invalid large request cannot trap during admission.
        let requestedLimit = min(max(query.limit, 1), 32)
        let limit = min(requestedLimit * 2, 64)
        let sql: String
        if terms.isEmpty {
            conditions.append("lower(r.content) LIKE ? ESCAPE '\\'")
            params.append(.text(likePattern(query.query)))
            sql = """
            SELECT r.rowid,r.id,r.kind,r.content,r.source_session_id,r.slot_key,r.created_at_ms,
                   COALESCE(r.valid_from_ms,r.created_at_ms),0.0
            FROM memory_record r WHERE \(conditions.joined(separator: " AND "))
            ORDER BY COALESCE(r.valid_from_ms,r.created_at_ms) DESC,r.id ASC LIMIT ?
            """
        } else {
            conditions.append("memory_record_fts MATCH ?")
            params.append(.text(terms))
            sql = """
            SELECT r.rowid,r.id,r.kind,r.content,r.source_session_id,r.slot_key,r.created_at_ms,
                   COALESCE(r.valid_from_ms,r.created_at_ms),bm25(memory_record_fts)
            FROM memory_record_fts f JOIN memory_record r ON r.rowid=f.rowid
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY bm25(memory_record_fts) ASC,COALESCE(r.valid_from_ms,r.created_at_ms) DESC,r.id ASC LIMIT ?
            """
        }
        params.append(.int(Int64(limit)))
        return try db.query(sql, params).map { row in
            let score = try normalizedBM25(row.dbl(8))
            return MemorySearchHit(
                id: try row.text(1), layer: "record", kind: try row.text(2), role: "",
                content: try row.text(3), score: score, sourceSessionID: try row.text(4),
                sourceMessageIDs: try evidenceSourceMessageIDs(recordID: try row.text(1)), slotKey: try row.optText(5)
            )
        }
    }

    func searchEvents(
        scope: Scope,
        query: String,
        limit: Int,
        excludingMessageIDs: Set<String> = [],
        fromMS: Int64? = nil,
        toMS: Int64? = nil
    ) throws -> [MemorySearchHit] {
        var conditions = ["e.workspace_id=?", "e.profile_id=?", "e.user_id=?", "e.namespace=?"]
        var params: [SQLValue] = [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace)]
        if excludingMessageIDs.isEmpty == false {
            let ids = excludingMessageIDs.sorted()
            conditions.append("e.source_message_id NOT IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")")
            params.append(contentsOf: ids.map(SQLValue.text))
        }
        if let fromMS { conditions.append("e.occurred_at_ms>=?"); params.append(.int(fromMS)) }
        if let toMS { conditions.append("e.occurred_at_ms<=?"); params.append(.int(toMS)) }
        let terms = ftsQuery(query)
        let capped = min(max(limit, 1), MemoryStoreLimits.maximumConsolidationPageSize)
        let sql: String
        if terms.isEmpty {
            conditions.append("lower(e.content) LIKE ? ESCAPE '\\'")
            params.append(.text(likePattern(query)))
            sql = """
            SELECT e.rowid,e.id,e.role,e.content,e.source_session_id,e.source_message_id,e.occurred_at_ms,0.0
            FROM memory_event e WHERE \(conditions.joined(separator: " AND "))
            ORDER BY e.occurred_at_ms DESC,e.id ASC LIMIT ?
            """
        } else {
            conditions.append("memory_event_fts MATCH ?")
            params.append(.text(terms))
            sql = """
            SELECT e.rowid,e.id,e.role,e.content,e.source_session_id,e.source_message_id,e.occurred_at_ms,
                   bm25(memory_event_fts)
            FROM memory_event_fts f JOIN memory_event e ON e.rowid=f.rowid
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY bm25(memory_event_fts) ASC,e.occurred_at_ms DESC,e.id ASC LIMIT ?
            """
        }
        params.append(.int(Int64(capped)))
        return try db.query(sql, params).map { row in
            MemorySearchHit(
                id: try row.text(1), layer: "event", kind: "event", role: try row.text(2),
                content: try row.text(3), score: try normalizedBM25(row.dbl(7)),
                sourceSessionID: try row.text(4), sourceMessageIDs: [try row.text(5)], slotKey: nil
            )
        }
    }

    func records(ids: [String]) throws -> [MemoryRecord] {
        guard ids.isEmpty == false else { return [] }
        let sorted = ids
        let sql = "SELECT rowid,id,workspace_id,profile_id,user_id,namespace,source_session_id,kind,slot_key,content,valid_from_ms,created_at_ms,content_hash FROM memory_record WHERE id IN (" + Array(repeating: "?", count: sorted.count).joined(separator: ",") + ")"
        return try db.query(sql, sorted.map(SQLValue.text)).map(memoryRecord)
    }

    func relations(for recordIDs: [String]) throws -> [MemoryRelation] {
        guard recordIDs.isEmpty == false else { return [] }
        let marks = Array(repeating: "?", count: recordIDs.count).joined(separator: ",")
        let params = recordIDs.map(SQLValue.text)
        let rows = try db.query(
            "SELECT from_record_id,relation,to_record_id FROM memory_relation WHERE from_record_id IN (\(marks)) OR to_record_id IN (\(marks)) ORDER BY from_record_id,relation,to_record_id",
            params + params
        )
        return try rows.map {
            guard let relation = MemoryRelationKind(rawValue: try $0.text(1)) else {
                throw AppError.storage("invalid_relation", "stored relation enum is invalid")
            }
            return MemoryRelation(fromRecordID: try $0.text(0), relation: relation, toRecordID: try $0.text(2))
        }
    }

    func evidenceSourceMessageIDs(recordID: String) throws -> [String] {
        try db.query(
            """
            SELECT DISTINCT e.source_message_id
            FROM memory_evidence ev
            JOIN memory_event e ON e.id=ev.event_id
            WHERE ev.record_id=?
            ORDER BY e.source_message_id ASC
            """,
            [.text(recordID)]
        ).map { try $0.text(0) }
    }

    private func appendEvidenceExclusion(
        conditions: inout [String],
        params: inout [SQLValue],
        recordAlias: String,
        excludingMessageIDs: Set<String>
    ) {
        guard excludingMessageIDs.isEmpty == false else { return }
        let ids = excludingMessageIDs.sorted()
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        conditions.append(
            """
            NOT EXISTS (
                SELECT 1
                FROM memory_evidence excluded_evidence
                JOIN memory_event excluded_event ON excluded_event.id=excluded_evidence.event_id
                WHERE excluded_evidence.record_id=\(recordAlias).id
                  AND excluded_event.source_message_id IN (\(marks))
            )
            """
        )
        params.append(contentsOf: ids.map(SQLValue.text))
    }

    func deleteScope(scope: Scope, forgetting: Bool = false) throws {
        try inTx {
            try advanceScopeGeneration(scope)
            if forgetting { try rememberForgottenInputs(scope) }
            try db.exec("DELETE FROM memory_record WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?", [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace)])
            try db.exec("DELETE FROM memory_event WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?", [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace)])
            try db.exec("DELETE FROM memory_checkpoint WHERE workspace_id=? AND profile_id=? AND user_id=? AND namespace=?", [.text(scope.workspaceID), .text(scope.profileID), .text(scope.userID), .text(scope.namespace)])
            try db.exec("INSERT INTO memory_record_fts(memory_record_fts) VALUES('rebuild')")
            try db.exec("INSERT INTO memory_event_fts(memory_event_fts) VALUES('rebuild')")
        }
    }

    private func makeMemoryEvent(
        scope: Scope,
        sourceSessionID: String,
        message: AgentMemoryIncomingMessage
    ) throws -> MemoryEvent? {
        guard let role = normalizeRole(message.role) else { return nil }
        guard !message.isHidden, !message.isSensitive else { return nil }
        let visible = sanitizeText(message.content)
        var normalized = ""
        switch role {
        case "user":
            normalized = visible
        case "assistant":
            normalized = visible
            if let toolCallsJSON = message.toolCallsJSON, !toolCallsJSON.isEmpty {
                normalized += (normalized.isEmpty ? "" : "\n") + "[tool_call \(sanitizeText(toolCallsJSON))]"
            }
        case "tool":
            let name = message.toolName.map(sanitizeText) ?? "tool"
            normalized = "[tool_result \(name)]" + (visible.isEmpty ? "" : " \(visible)")
        default:
            return nil
        }
        guard shouldCaptureEvent(normalized) else { return nil }
        try validateContent(normalized)
        let id = stableID(
            "event_v1",
            "1", scope.workspaceID, scope.profileID, scope.userID, scope.namespace, message.id
        )
        return MemoryEvent(
            rowID: 0, id: id, workspaceID: scope.workspaceID, profileID: scope.profileID,
            userID: scope.userID, namespace: scope.namespace, sourceSessionID: sourceSessionID,
            sourceMessageID: message.id, sourceIndex: message.sourceIndex, role: role, content: normalized,
            occurredAtMS: message.occurredAtMS, contentHash: contentHash(normalized), metadataJSON: "{}"
        )
    }

    private func normalizeRole(_ role: String) -> String? {
        switch role { case "user", "assistant", "tool": return role; default: return nil }
    }

    private func memoryEvent(_ row: SQLRow) throws -> MemoryEvent {
        MemoryEvent(
            rowID: try row.int(0), id: try row.text(1), workspaceID: try row.text(2), profileID: try row.text(3),
            userID: try row.text(4), namespace: try row.text(5), sourceSessionID: try row.text(6),
            sourceMessageID: try row.text(7), sourceIndex: try row.optInt(8).map(Int.init), role: try row.text(9), content: try row.text(10),
            occurredAtMS: try row.int(11), contentHash: try row.text(12), metadataJSON: try row.text(13)
        )
    }

    private func memoryRecord(_ row: SQLRow) throws -> MemoryRecord {
        guard let kind = ProjectionRecordKind(rawValue: try row.text(7)) else {
            throw AppError.storage("invalid_record_kind", "stored memory record kind is invalid")
        }
        return MemoryRecord(
            rowID: try row.int(0), id: try row.text(1), workspaceID: try row.text(2), profileID: try row.text(3),
            userID: try row.text(4), namespace: try row.text(5), sourceSessionID: try row.text(6), kind: kind,
            slotKey: try row.optText(8), content: try row.text(9), validFromMS: try row.optInt(10),
            createdAtMS: try row.int(11), contentHash: try row.text(12)
        )
    }

    private func memoryCheckpoint(_ row: SQLRow) throws -> MemoryCheckpoint {
        MemoryCheckpoint(
            workspaceID: try row.text(0), profileID: try row.text(1), userID: try row.text(2), namespace: try row.text(3),
            sourceSessionID: try row.text(4), messageCount: Int(try row.int(5)), agentRevision: try row.int(6),
            consolidatedRowID: try row.int(7), lastSourceMessageID: try row.text(8),
            lastSourceContentHash: try row.text(9), lastSourceRole: try row.text(10), lastSourceOccurredAtMS: try row.int(11)
        )
    }

    private func ftsQuery(_ query: String) -> String {
        query.split { !( $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ) }
            .map(String.init).filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " OR ")
    }

    private func likePattern(_ query: String) -> String {
        let escaped = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func normalizedBM25(_ value: Double) throws -> Double {
        guard value.isFinite else { throw AppError.storage("invalid_search_score", "SQLite returned a non-finite BM25 score") }
        if value <= 0 { return min(1, max(0, 1 / (1 + max(0, -value)))) }
        return min(1, max(0, 1 / (1 + value)))
    }
}
