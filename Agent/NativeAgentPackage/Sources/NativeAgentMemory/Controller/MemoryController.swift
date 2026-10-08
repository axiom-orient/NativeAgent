import NativeAgentDomain
import NativeAgent
internal import NativeAgentMemoryProjection
import Foundation

public actor MemoryController {
    public nonisolated let configuration: MemoryConfiguration
    private let engine: AgentMemoryEngine

    public init(configuration: MemoryConfiguration) {
        self.configuration = configuration
        self.engine = AgentMemoryEngine(configuration: configuration.agentMemoryConfiguration)
    }

    @discardableResult
    public func prepare() async throws -> URL {
        do {
            try Task.checkCancellation()
            let info = try await engine.prepare()
            return info.dataDirectory
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    /// Pulls committed transcript pages and advances the checkpoint only after
    /// each complete page is inserted. A fetch or insert failure therefore
    /// cannot skip unobserved messages.
    @discardableResult
    public func sync(
        sessionID: String,
        from source: any MemoryTranscriptSource
    ) async throws -> MemorySyncResult {
        try await sync(
            scope: MemoryScope(
                profileID: configuration.defaultProfileID,
                userID: configuration.defaultUserID,
                namespace: configuration.namespace
            ),
            sessionID: sessionID,
            from: source
        )
    }

    /// Pulls a transcript into the configured namespace while retaining the
    /// source session only as provenance. The supplied scope is the retrieval
    /// scope; it is never replaced with the session id.
    @discardableResult
    public func sync(
        scope: MemoryScope,
        sessionID: String,
        from source: any MemoryTranscriptSource
    ) async throws -> MemorySyncResult {
        do {
            try Task.checkCancellation()
            guard sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw MemoryError.memoryFailure(code: "missing_session_id", message: "transcript sync requires a session id")
            }
            _ = try await prepare()
            var sourceScope = scope
            if sourceScope.profileID.isEmpty { sourceScope = MemoryScope(profileID: configuration.defaultProfileID, userID: sourceScope.userID, sessionKey: sourceScope.sessionKey, namespace: sourceScope.namespace) }
            if sourceScope.userID.isEmpty { sourceScope = MemoryScope(profileID: sourceScope.profileID, userID: configuration.defaultUserID, sessionKey: sourceScope.sessionKey, namespace: sourceScope.namespace) }
            if sourceScope.namespace.isEmpty { sourceScope = MemoryScope(profileID: sourceScope.profileID, userID: sourceScope.userID, sessionKey: sourceScope.sessionKey, namespace: configuration.namespace) }
            let generation = try await engine.scopeGeneration(scope: AgentMemoryScope(sourceScope))
            let journal = try await transcriptJournal(from: source, sessionID: sessionID)
            guard journal.sessionID == sessionID else {
                throw MemoryError.memoryFailure(code: "transcript_identity_mismatch", message: "journal session id does not match the requested session")
            }
            let count = journal.messageCount
            let checkpointCount = try await engine.checkpointMessageCount(
                scope: AgentMemoryScope(sourceScope),
                sessionID: sessionID
            )
            guard count >= 0, checkpointCount >= 0, checkpointCount <= count else {
                throw MemoryError.memoryFailure(code: "invalid_transcript_page", message: "transcript journal checkpoint is outside the committed journal")
            }
            let probe: AgentMemoryIncomingMessage?
            if checkpointCount > 0 {
                let page = try await transcriptPage(
                    from: source,
                    sessionID: sessionID,
                    offset: checkpointCount - 1,
                    limit: 1,
                    operation: "memory.sync.tail_probe"
                )
                guard page.sessionID == sessionID,
                      page.offset == checkpointCount - 1, page.totalCount == count, page.messages.count == 1 else {
                    throw MemoryError.memoryFailure(code: "invalid_transcript_page", message: "transcript tail probe is inconsistent with the journal")
                }
                probe = try incomingMessage(page.messages[0], sourceIndex: checkpointCount - 1)
            } else {
                probe = nil
            }
            let plan = try await engine.syncPlan(
                scope: AgentMemoryScope(sourceScope), sessionID: sessionID,
                journal: AgentMemoryJournalState(messageCount: count, revision: journal.revision),
                lastMessage: probe, expectedGeneration: generation
            )
            if plan.noOp {
                return MemorySyncResult(sessionID: sessionID, scannedMessages: 0, insertedEvents: 0, messageCount: count, revision: journal.revision)
            }
            guard plan.offset >= 0, plan.offset <= count else {
                throw MemoryError.memoryFailure(code: "invalid_transcript_page", message: "transcript sync plan is outside the committed journal")
            }
            var offset = plan.offset
            var scanned = 0
            var inserted = 0
            while offset < count {
                try Task.checkCancellation()
                let page = try await transcriptPage(
                    from: source,
                    sessionID: sessionID,
                    offset: offset,
                    limit: 100,
                    operation: "memory.sync.page"
                )
                guard page.sessionID == sessionID,
                      page.offset == offset, page.totalCount == count, page.messages.isEmpty == false,
                      page.messages.count <= 100 else {
                    throw MemoryError.memoryFailure(code: "invalid_transcript_page", message: "transcript page is not contiguous or complete")
                }
                let pageEnd = try checkedMemoryAddition(
                    offset, page.messages.count,
                    message: "transcript page end overflowed the supported integer range"
                )
                guard pageEnd <= count else {
                    throw MemoryError.memoryFailure(code: "invalid_transcript_page", message: "transcript page is not contiguous or complete")
                }
                let incoming = try page.messages.enumerated().map { index, message in
                    let sourceIndex = try checkedMemoryAddition(
                        offset, index,
                        message: "transcript message index overflowed the supported integer range"
                    )
                    return try incomingMessage(message, sourceIndex: sourceIndex)
                }
                let result = try await engine.applySyncPage(
                    scope: AgentMemoryScope(sourceScope), sessionID: sessionID,
                    journal: AgentMemoryJournalState(messageCount: count, revision: journal.revision),
                    page: AgentMemoryIncomingPage(offset: offset, totalCount: page.totalCount, messages: incoming),
                    expectedOffset: offset, expectedGeneration: generation
                )
                scanned = try checkedMemoryAddition(
                    scanned, result.scannedMessages,
                    message: "scanned transcript count overflowed the supported integer range"
                )
                inserted = try checkedMemoryAddition(
                    inserted, result.insertedEvents,
                    message: "inserted memory event count overflowed the supported integer range"
                )
                offset = pageEnd
            }
            return MemorySyncResult(sessionID: sessionID, scannedMessages: scanned, insertedEvents: inserted, messageCount: count, revision: journal.revision)
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    @discardableResult
    public func capture(
        scope: MemoryScope,
        messages: [AgentMessage]
    ) async throws -> MemoryCaptureResult {
        let turns = messages.compactMap { message -> MemoryTurn? in
            guard let role = MemoryRole(rawValue: message.role.rawValue) else { return nil }
            return MemoryTurn(
                id: message.id, role: role, content: message.content,
                timestampMilliseconds: Int64(message.createdAt.timeIntervalSince1970 * 1_000),
                sessionID: scope.sessionKey, sessionKey: scope.sessionKey,
                toolName: message.toolName,
                toolCallsJSON: toolCallsJSON(message.toolCalls),
                metadata: message.metadata.reduce(into: [String: String]()) { result, item in
                    if item.value.boolValue == true { result[item.key] = "true" }
                }
            )
        }
        return try await capture(scope: scope, turns: turns)
    }

    @discardableResult
    public func capture(
        scope: MemoryScope,
        turns: [MemoryTurn]
    ) async throws -> MemoryCaptureResult {
        do {
            try Task.checkCancellation()
            guard turns.isEmpty == false else { throw MemoryError.emptyCapture }
            let result = try await engine.ingest(
                scope: AgentMemoryScope(scope), turns: turns.map(AgentMemoryTurn.init)
            )
            return MemoryCaptureResult(result)
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    public func recall(
        scope: MemoryScope,
        query: String,
        maxResults: Int? = nil,
        excludingMessageIDs: Set<String> = []
    ) async throws -> MemoryContext {
        do {
            _ = try await prepare()
            let result = try await engine.recall(
                scope: AgentMemoryScope(scope), query: query,
                excludingMessageIDs: excludingMessageIDs,
                maxResults: min(max(maxResults ?? configuration.maxContextResults, 1), 8)
            )
            return MemoryContext(result)
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    public func search(
        scope: MemoryScope,
        query: String,
        maxResults: Int? = nil
    ) async throws -> MemorySearchResult {
        try await search(
            scope: scope,
            query: MemorySearchQuery(query: query, limit: maxResults ?? 8)
        )
    }

    public func search(
        scope: MemoryScope,
        query: MemorySearchQuery
    ) async throws -> MemorySearchResult {
        do {
            _ = try await prepare()
            let internalQuery = ProjectionSearchQuery(
                query: query.query,
                kinds: Set(query.kinds.compactMap { ProjectionRecordKind(rawValue: $0.rawValue) }),
                fromMS: query.fromMilliseconds,
                toMS: query.toMilliseconds,
                historical: query.historical,
                limit: min(max(query.limit, 1), 8)
            )
            let hits = try await engine.search(scope: AgentMemoryScope(scope), query: internalQuery)
            return MemorySearchResult(
                query: query.query,
                matches: hits.map(MemoryMatch.init),
                historical: query.historical
            )
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    public func capabilities() async throws -> MemoryCapabilities {
        do {
            _ = try await prepare()
            return MemoryCapabilities(try await engine.capabilities())
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    @discardableResult
    public func consolidatePending(
        scope: MemoryScope,
        sessionID: String,
        provider: any MemoryConsolidationProvider
    ) async throws -> MemoryConsolidationResult {
        do {
            _ = try await prepare()
            guard sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw MemoryError.memoryFailure(code: "missing_session_id", message: "consolidation requires a source session id")
            }
            let result = try await engine.consolidate(
                scope: AgentMemoryScope(scope), sessionID: sessionID,
                provider: MemoryLLMProvider(provider: provider)
            )
            return MemoryConsolidationResult(
                insertedRecords: result.insertedRecords,
                insertedRelations: result.insertedRelations,
                closedThroughEventID: result.closedThroughEventID
            )
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    public func delete(scope: MemoryScope) async throws {
        do {
            _ = try await prepare()
            try await engine.delete(scope: AgentMemoryScope(scope))
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    /// Removes the observed memory projection and durably suppresses its known
    /// message IDs and transcript prefixes. New appended messages may be captured.
    /// Does not erase the source journal, unobserved transcripts, or exports.
    /// `delete` remains a projection reset and does not undo this suppression.
    public func forget(scope: MemoryScope) async throws {
        do {
            _ = try await prepare()
            try Task.checkCancellation()
            try await engine.forget(scope: AgentMemoryScope(scope))
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw mapMemoryError(error)
        }
    }

    private func transcriptJournal(
        from source: any MemoryTranscriptSource,
        sessionID: String
    ) async throws -> AgentJournalRecord {
        do {
            return try await source.journalRecord(sessionID: sessionID)
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw transcriptFailure(
                error,
                operation: "memory.sync.journal",
                context: ["sessionID": sessionID]
            )
        }
    }

    private func transcriptPage(
        from source: any MemoryTranscriptSource,
        sessionID: String,
        offset: Int,
        limit: Int,
        operation: String
    ) async throws -> SessionMessagePage {
        do {
            return try await source.messages(sessionID: sessionID, offset: offset, limit: limit)
        } catch {
            if isMemoryCancellation(error) { throw CancellationError() }
            throw transcriptFailure(
                error,
                operation: operation,
                context: [
                    "sessionID": sessionID,
                    "offset": String(offset),
                    "limit": String(limit),
                ]
            )
        }
    }

    private func transcriptFailure(
        _ error: any Error,
        operation: String,
        context: [String: String]
    ) -> MemoryError {
        let cause = String(decoding: String(describing: error).utf8.prefix(4_096), as: UTF8.self)
        return .detailedMemoryFailure(
            operation: operation,
            code: "transcript_source_failure",
            message: "Committed transcript read failed.",
            cause: cause,
            context: context
        )
    }

    private func checkedMemoryAddition(
        _ lhs: Int,
        _ rhs: Int,
        message: String
    ) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw MemoryError.memoryFailure(code: "invalid_transcript_page", message: message)
        }
        return result
    }

    private func incomingMessage(_ message: AgentMessage, sourceIndex: Int? = nil) throws -> AgentMemoryIncomingMessage {
        let calls = toolCallsJSON(message.toolCalls)
        let rawIdentity = [
            message.id, message.role.rawValue, message.content,
            message.toolName ?? "", message.toolCallID ?? "",
            calls ?? "", String(message.createdAt.timeIntervalSince1970)
        ].joined(separator: "\u{0}")
        let admission = MemoryCaptureAdmission.flags(for: message.metadata)
        return AgentMemoryIncomingMessage(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            occurredAtMS: Int64(message.createdAt.timeIntervalSince1970 * 1_000),
            toolName: message.toolName,
            toolCallsJSON: calls,
            sourceIndex: sourceIndex,
            isHidden: admission.isHidden,
            isSensitive: admission.isSensitive,
            rawContentHash: digest(rawIdentity)
        )
    }
}

private struct MemoryLLMProvider: AgentMemoryLLMProvider {
    let provider: any MemoryConsolidationProvider

    func generate(_ request: AgentMemoryGenerateRequest) async throws -> AgentMemoryGenerateResponse {
        let text = try await provider.generateMemoryText(
            system: request.system,
            messages: request.messages.map { MemoryGenerationMessage(role: $0.role, content: $0.content) }
        )
        return AgentMemoryGenerateResponse(content: text)
    }
}

private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}

private func toolCallsJSON(_ calls: [ToolCall]) -> String? {
    guard calls.isEmpty == false else { return nil }
    let values = calls.map { call in
        "{\"id\":\"\(escape(call.id))\",\"name\":\"\(escape(call.name))\",\"arguments\":\(call.arguments.displayString())}"
    }
    return "[\(values.joined(separator: ","))]"
}

private func digest(_ value: String) -> String {
    // AgentMemoryEngine owns the hashing primitive; this local identity only
    // needs deterministic bytes for transcript rewrite detection.
    String(value.utf8.reduce(into: UInt64(1469598103934665603)) { hash, byte in
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }, radix: 16)
}
