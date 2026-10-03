import Foundation
import NativeAgentDomain

extension SessionCoordinator {
    public func queueCommand(
        sessionID: String,
        input: String,
        identity: AgentCommandIdentity,
        metadata: [String: JSONValue]
    ) async throws -> AgentCommandReceipt {
        try validateCommand(identity)
        guard input.isEmpty == false else {
            throw AgentError.invalidConfiguration("Queued input must not be empty.")
        }
        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(sessionID: sessionID)
            try validate(identity, for: snapshot)
            let message = AgentMessage(
                id: idGenerator(),
                role: .user,
                content: input,
                createdAt: now(),
                metadata: metadata
            )
            var marked = snapshot
            marked = try SessionSnapshotTransitions.replacingMetadata(
                commandMetadata(identity, in: snapshot.metadata),
                in: snapshot
            )
            let reduction = try SessionSnapshotTransitions.appendingUserMessage(
                message,
                to: marked,
                timestamp: now()
            )
            let persisted = try await snapshotWriter.persist(reduction)
            return AgentCommandReceipt(
                operationID: identity.operationID,
                sessionID: sessionID,
                revision: persisted.revision
            )
        }
    }

    public func editCommand(
        sessionID: String,
        messageID: String,
        input: String,
        identity: AgentCommandIdentity,
        metadata: [String: JSONValue]
    ) async throws -> AgentCommandReceipt {
        try validateCommand(identity)
        guard messageID.isEmpty == false, input.isEmpty == false else {
            throw AgentError.invalidConfiguration("Edit identifiers and input must not be empty.")
        }
        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(sessionID: sessionID)
            try validate(identity, for: snapshot)
            guard snapshot.messages.contains(where: { $0.id == messageID && $0.role == .user }) else {
                throw AgentError.invariantViolation("Edit target is not a user message.")
            }
            var messageMetadata = metadata
            messageMetadata["native-agent.command.editOf"] = .string(messageID)
            let message = AgentMessage(
                id: idGenerator(),
                role: .user,
                content: input,
                createdAt: now(),
                metadata: messageMetadata
            )
            let marked = try SessionSnapshotTransitions.replacingMetadata(
                commandMetadata(identity, in: snapshot.metadata),
                in: snapshot
            )
            let reduction = try SessionSnapshotTransitions.appendingUserMessage(
                message,
                to: marked,
                timestamp: now()
            )
            let persisted = try await snapshotWriter.persist(reduction)
            return AgentCommandReceipt(
                operationID: identity.operationID,
                sessionID: sessionID,
                revision: persisted.revision
            )
        }
    }

    public func retryCommand(
        sessionID: String,
        identity: AgentCommandIdentity
    ) async throws -> SessionSnapshot {
        try validateCommand(identity)
        let inspection = try await inspectRecovery(sessionID: sessionID)
        guard inspection.requiresHostReconciliation == false,
              inspection.pendingToolEffects.contains(where: { $0.disposition == .invalid }) == false,
              inspection.snapshot.waitState?.kind != .approval,
              inspection.snapshot.waitState?.kind != .modelInvocation,
              inspection.snapshot.waitState?.kind != .signal else {
            throw AgentError.invariantViolation(
                "Retry is blocked until pending effects, approvals, or waits are resolved."
            )
        }
        guard inspection.snapshot.revision == identity.expectedRevision else {
            throw AgentError.invariantViolation("Command revision is stale.")
        }
        guard inspection.snapshot.status == .failed || inspection.snapshot.status == .running else {
            throw AgentError.invariantViolation("Retry requires a failed or running session.")
        }
        return try await withSessionExecution(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshotForAdvancement(sessionID: sessionID)
            try validate(identity, for: snapshot)
            let marked = try SessionSnapshotTransitions.replacingMetadata(
                commandMetadata(identity, in: snapshot.metadata),
                in: snapshot
            )
            let reduction: SessionReduction
            if marked.status == .failed {
                guard let resumed = try SessionSnapshotTransitions.resumeIfNeeded(
                    marked,
                    timestamp: now()
                ) else {
                    throw AgentError.invariantViolation("Failed retry did not produce a resume transition.")
                }
                reduction = resumed
            } else {
                reduction = try SessionReducer.reduce(
                    .replaceMessages(
                        marked.messages,
                        updatedAt: now(),
                        reason: .statusResumedToRunning
                    ),
                    state: marked
                )
            }
            let persisted = try await snapshotWriter.persist(reduction)
            return try await advanceLoadedSnapshot(persisted)
        }
    }

    public func forkCommand(
        sessionID: String,
        throughMessageIndex: Int,
        newSessionID: String,
        identity: AgentCommandIdentity,
        title: String?,
        metadata: [String: JSONValue]
    ) async throws -> AgentCommandReceipt {
        try validateCommand(identity)
        guard newSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invalidConfiguration("Fork session identifier must not be empty.")
        }
        try await store.prepare()
        return try await withSessionExecution(sessionID: sessionID) {
            let source = try await loadExistingSnapshot(sessionID: sessionID)
            guard (0...source.messages.count).contains(throughMessageIndex) else {
                throw AgentError.invalidConfiguration("Fork transcript point is outside the source transcript.")
            }
            let throughMessageIndexValue = JSONValue.integer(Int64(throughMessageIndex))
            let requestedIntent: JSONValue = .object([
                "newSessionID": .string(newSessionID),
                "throughMessageIndex": throughMessageIndexValue,
                "title": title.map(JSONValue.string) ?? .null,
                "metadata": .object(metadata),
            ])
            let recordedIntent = source.metadata["native-agent.command.forkIntents"]?
                .objectValue?[identity.operationID]

            if let recordedIntent {
                guard var recordedObject = recordedIntent.objectValue else {
                    throw AgentError.invariantViolation(
                        "Fork command operation identifier conflicts with its durable intent."
                    )
                }
                guard let sourceRevision = recordedObject.removeValue(forKey: "sourceRevision"),
                      let sourceRevisionValue = sourceRevision.intValue,
                      sourceRevisionValue >= 0 else {
                    throw AgentError.invariantViolation(
                        "Fork command intent is missing a valid source revision."
                    )
                }
                let recordedSourceRevision = Int64(sourceRevisionValue)
                guard JSONValue.object(recordedObject) == requestedIntent else {
                    throw AgentError.invariantViolation(
                        "Fork command operation identifier conflicts with its durable intent."
                    )
                }
                guard identity.expectedRevision == recordedSourceRevision else {
                    throw AgentError.invariantViolation(
                        "Fork command operation identifier conflicts with its durable revision."
                    )
                }
                guard let existing = try await store.loadSnapshot(sessionID: newSessionID) else {
                    throw AgentError.invariantViolation(
                        "Atomic fork intent exists without its target session."
                    )
                }
                let expectedProvenance: JSONValue = .object([
                    "operationID": .string(identity.operationID),
                    "sourceSessionID": .string(sessionID),
                    "throughMessageIndex": throughMessageIndexValue,
                    "intent": recordedIntent,
                ])
                guard existing.metadata["native-agent.command.fork"] == expectedProvenance else {
                    throw AgentError.invariantViolation(
                        "Fork target exists without matching operation identity."
                    )
                }
                return AgentCommandReceipt(
                    operationID: identity.operationID,
                    sessionID: newSessionID,
                    revision: existing.revision
                )
            }

            try validate(identity, for: source)
            guard try await store.loadSnapshot(sessionID: newSessionID) == nil else {
                throw AgentError.invariantViolation(
                    "Fork session identifier already exists: \(newSessionID)."
                )
            }

            var intentObject = requestedIntent.objectValue ?? [:]
            intentObject["sourceRevision"] = .integer(source.revision)
            let intent = JSONValue.object(intentObject)
            let timestamp = now()
            let transcript = source.messages.prefix(throughMessageIndex).compactMap { message -> AgentMessage? in
                guard message.role != .tool else { return nil }
                return AgentMessage(
                    id: idGenerator(),
                    role: message.role,
                    contentParts: message.contentParts,
                    createdAt: message.createdAt,
                    metadata: [:]
                )
            }
            var forkMetadata = metadata
            forkMetadata["native-agent.command.fork"] = .object([
                "operationID": .string(identity.operationID),
                "sourceSessionID": .string(sessionID),
                "throughMessageIndex": throughMessageIndexValue,
                "intent": intent,
            ])
            let fork = SessionSnapshot(
                sessionID: newSessionID,
                title: title ?? source.title,
                status: .running,
                createdAt: timestamp,
                updatedAt: timestamp,
                messages: transcript,
                providerID: source.providerID,
                modelID: source.modelID,
                metadata: forkMetadata
            )

            var sourceMetadata = commandMetadata(identity, in: source.metadata)
            var intents = sourceMetadata["native-agent.command.forkIntents"]?.objectValue ?? [:]
            intents[identity.operationID] = intent
            sourceMetadata["native-agent.command.forkIntents"] = .object(intents)
            let sourceReduction = try SessionReducer.reduce(
                .recordCommand(sourceMetadata, updatedAt: timestamp),
                state: source
            )

            _ = try await snapshotWriter.fork(
                source: sourceReduction,
                target: fork,
                targetJournalEntries: [
                    .sessionForked(sourceSessionID: sessionID)
                ]
            )
            return AgentCommandReceipt(
                operationID: identity.operationID,
                sessionID: newSessionID,
                revision: fork.revision
            )
        }
    }

    private func validateCommand(_ identity: AgentCommandIdentity) throws {
        guard (1...128).contains(identity.operationID.utf8.count),
              identity.operationID.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57)
                      || ($0.value >= 65 && $0.value <= 90)
                      || ($0.value >= 97 && $0.value <= 122)
                      || $0.value == 46 || $0.value == 45 || $0.value == 95
              }),
              identity.expectedRevision >= 0 else {
            throw AgentError.invalidConfiguration("Command identity is malformed.")
        }
    }

    private func validate(_ identity: AgentCommandIdentity, for snapshot: SessionSnapshot) throws {
        guard snapshot.revision == identity.expectedRevision else {
            throw AgentError.invariantViolation("Command revision is stale.")
        }
        let operations = snapshot.metadata["native-agent.command.operations"]?.objectValue ?? [:]
        guard operations.count < 4_096 else {
            throw AgentError.budgetExceeded("Durable command identity history exceeds 4096 entries.")
        }
        guard operations[identity.operationID] == nil else {
            throw AgentError.invariantViolation("Command operation identifier was already used.")
        }
    }

    private func commandMetadata(
        _ identity: AgentCommandIdentity,
        in metadata: [String: JSONValue]
    ) -> [String: JSONValue] {
        var metadata = metadata
        var operations = metadata["native-agent.command.operations"]?.objectValue ?? [:]
        operations[identity.operationID] = .integer(identity.expectedRevision)
        metadata["native-agent.command.operations"] = .object(operations)
        return metadata
    }
}
