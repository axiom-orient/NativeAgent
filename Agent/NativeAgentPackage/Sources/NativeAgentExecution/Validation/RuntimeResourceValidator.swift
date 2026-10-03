import Foundation
import NativeAgentDomain

struct RuntimeSessionValidationIndex: Sendable {
    let sessionID: String
    let revision: Int64
    let messageCount: Int
    let leadingSystemMessageCount: Int
    let toolCallsByID: [String: ToolCall]
    let artifactCount: Int
    let artifactIDs: Set<String>
    let totalArtifactBytes: Int
}

struct RuntimeResourceValidator: Sendable {
    let limits: RuntimeResourceLimits

    private var jsonStructureLimits: JSONValueStructureLimits {
        JSONValueStructureLimits(
            maximumDepth: limits.maxJSONDepth,
            maximumNodes: limits.maxJSONNodes,
            maximumCollectionEntries: limits.maxJSONCollectionEntries,
            maximumStringUTF8Bytes: limits.maxJSONStringUTF8Bytes,
            maximumKeyUTF8Bytes: limits.maxJSONKeyUTF8Bytes,
            maximumTotalStringUTF8Bytes: limits.maxJSONTotalStringUTF8Bytes
        )
    }

    func validate(toolDefinitions: [ToolDefinition]) throws {
        guard toolDefinitions.count <= limits.maxToolCount else {
            throw AgentError.invalidConfiguration(
                "Configured tool count \(toolDefinitions.count) exceeds maxToolCount \(limits.maxToolCount)."
            )
        }

        for definition in toolDefinitions {
            guard ModelToolContract.isValidName(definition.name) else {
                throw AgentError.invalidConfiguration(
                    "Tool name must satisfy the model contract (ASCII alphanumeric, '-', '_', '.', max \(ModelToolContract.maximumNameUTF8Bytes) UTF-8 bytes)."
                )
            }
            try validateIdentifier(definition.name, field: "tool name")
            guard definition.description.utf8.count <= ModelToolContract.maximumDescriptionUTF8Bytes else {
                throw AgentError.invalidConfiguration(
                    "Tool description \(definition.name) exceeds the model contract limit of \(ModelToolContract.maximumDescriptionUTF8Bytes) UTF-8 bytes."
                )
            }
            try validateIdentifier(
                definition.capabilityID.rawValue,
                field: "tool capability \(definition.name)"
            )
            try validateJSON(
                definition.inputSchema,
                field: "tool schema \(definition.name)",
                maximumCanonicalUTF8Bytes: limits.maxToolArgumentsUTF8Bytes
            )
            do {
                _ = try ToolSchemaDescriptor(
                    schema: definition.inputSchema,
                    path: definition.name
                )
            } catch let error as AgentError {
                throw AgentError.invalidConfiguration(
                    "Tool schema \(definition.name) is not supported: \(error.localizedDescription)"
                )
            }
            try validateMetadata(
                definition.metadata,
                field: "tool metadata \(definition.name)"
            )
        }
    }

    func validateUserPrompt(_ prompt: String) throws {
        try validateText(prompt, field: "user prompt")
    }

    func validateUserMessage(_ message: AgentMessage) throws {
        guard message.role == .user else {
            throw AgentError.invalidConfiguration("Only a user message can start or continue a session.")
        }
        guard !message.contentParts.isEmpty else {
            throw AgentError.invalidConfiguration("A user message must contain at least one content part.")
        }
        try validate(message: message, contentField: "user message")
    }

    func validateSignalPayload(_ payload: JSONValue) throws {
        try validateJSON(
            payload,
            field: "signal payload",
            maximumCanonicalUTF8Bytes: limits.maxToolArgumentsUTF8Bytes
        )
    }

    func validate(snapshot: SessionSnapshot) throws {
        _ = try validatedIndex(snapshot: snapshot)
    }

    /// Cheap admission performed before full transcript/artifact hydration.
    func validate(admission: SessionRuntimeAdmission) throws {
        guard admission.schemaVersion == SessionSnapshot.currentSchemaVersion else {
            throw AgentError.persistenceFailure(
                "Unsupported durable session schema version: \(admission.schemaVersion)."
            )
        }
        guard admission.revision >= 0 else {
            throw AgentError.persistenceFailure("Session admission has a negative revision.")
        }
        guard admission.messageCount >= 0 else {
            throw AgentError.persistenceFailure("Session admission has a negative message count.")
        }
        guard admission.hydrationPayloadBytes >= 0 else {
            throw AgentError.persistenceFailure(
                "Session admission has a negative hydration payload byte count."
            )
        }
        guard admission.artifactCount >= 0 else {
            throw AgentError.persistenceFailure("Session admission has a negative artifact count.")
        }
        guard admission.messageCount <= limits.maxTranscriptMessages else {
            throw AgentError.budgetExceeded(
                "Transcript contains \(admission.messageCount) messages; limit is \(limits.maxTranscriptMessages)."
            )
        }
        guard admission.hydrationPayloadBytes <= limits.maxSessionHydrationPayloadBytes else {
            throw AgentError.budgetExceeded(
                "Persisted session hydration payload is \(admission.hydrationPayloadBytes) bytes; limit is \(limits.maxSessionHydrationPayloadBytes)."
            )
        }
        guard admission.artifactCount <= limits.maxSessionArtifacts else {
            throw AgentError.budgetExceeded(
                "Session contains \(admission.artifactCount) artifacts; limit is \(limits.maxSessionArtifacts)."
            )
        }
    }

    func validatedIndex(snapshot: SessionSnapshot) throws -> RuntimeSessionValidationIndex {
        try validateEnvelope(snapshot: snapshot, checkpointPrefixValidation: true)

        var toolCallsByID: [String: ToolCall] = [:]
        for message in snapshot.messages {
            try validate(message: message, contentField: "message \(message.id)")
            try addToolCalls(
                message.toolCalls,
                sessionID: snapshot.sessionID,
                to: &toolCallsByID
            )
        }

        var totalArtifactBytes = 0
        var artifactIDs: Set<String> = []
        for artifact in snapshot.artifacts {
            try validateAndAdd(
                artifact,
                sessionID: snapshot.sessionID,
                totalArtifactBytes: &totalArtifactBytes,
                artifactIDs: &artifactIDs
            )
        }

        return RuntimeSessionValidationIndex(
            sessionID: snapshot.sessionID,
            revision: snapshot.revision,
            messageCount: snapshot.messages.count,
            leadingSystemMessageCount:
                snapshot.messages.firstIndex(where: { $0.role != .system })
                ?? snapshot.messages.count,
            toolCallsByID: toolCallsByID,
            artifactCount: snapshot.artifacts.count,
            artifactIDs: artifactIDs,
            totalArtifactBytes: totalArtifactBytes
        )
    }

    func validatedIndex(
        snapshot: SessionSnapshot,
        delta: SessionPersistenceDelta,
        previous: RuntimeSessionValidationIndex
    ) throws -> RuntimeSessionValidationIndex {
        guard previous.sessionID == snapshot.sessionID,
              previous.revision == delta.expectedRevision,
              delta.expectedRevision < Int64.max,
              snapshot.revision == delta.expectedRevision + 1 else {
            throw AgentError.persistenceFailure(
                "Session \(snapshot.sessionID) validation index does not match persistence revision."
            )
        }
        try validateEnvelope(snapshot: snapshot, checkpointPrefixValidation: false)

        var messageCount = previous.messageCount
        var leadingSystemMessageCount = previous.leadingSystemMessageCount
        var toolCallsByID = previous.toolCallsByID
        switch delta.messages {
        case .unchanged:
            guard snapshot.messages.count == previous.messageCount else {
                throw AgentError.invariantViolation(
                    "Unchanged message delta changed the transcript count."
                )
            }

        case .append(let startingAt, let messages):
            guard startingAt == previous.messageCount,
                  snapshot.messages.count == startingAt + messages.count,
                  snapshot.messages[startingAt...].elementsEqual(messages) else {
                throw AgentError.invariantViolation(
                    "Appended message delta does not match the resulting transcript."
                )
            }
            for message in messages {
                try validate(message: message, contentField: "message \(message.id)")
                try addToolCalls(
                    message.toolCalls,
                    sessionID: snapshot.sessionID,
                    to: &toolCallsByID
                )
            }
            if startingAt == leadingSystemMessageCount {
                leadingSystemMessageCount += messages.prefix {
                    $0.role == .system
                }.count
            }
            messageCount = snapshot.messages.count

        case .replace(let messages):
            guard snapshot.messages.elementsEqual(messages) else {
                throw AgentError.invariantViolation(
                    "Replacement message delta does not match the resulting transcript."
                )
            }
            toolCallsByID.removeAll(keepingCapacity: true)
            for message in messages {
                try validate(message: message, contentField: "message \(message.id)")
                try addToolCalls(
                    message.toolCalls,
                    sessionID: snapshot.sessionID,
                    to: &toolCallsByID
                )
            }
            messageCount = messages.count
            leadingSystemMessageCount =
                messages.firstIndex(where: { $0.role != .system }) ?? messages.count
        }

        if let checkpoint = snapshot.contextCheckpoint,
           checkpoint.preservedSystemMessageCount > leadingSystemMessageCount {
            throw AgentError.persistenceFailure(
                "Session \(snapshot.sessionID) has an invalid context checkpoint prefix."
            )
        }

        var artifactCount = previous.artifactCount
        var artifactIDs = previous.artifactIDs
        var totalArtifactBytes = previous.totalArtifactBytes
        switch delta.artifacts {
        case .unchanged:
            guard snapshot.artifacts.count == previous.artifactCount else {
                throw AgentError.invariantViolation(
                    "Unchanged artifact delta changed the artifact count."
                )
            }

        case .append(let startingAt, let artifacts):
            guard startingAt == previous.artifactCount,
                  snapshot.artifacts.count == startingAt + artifacts.count,
                  snapshot.artifacts[startingAt...].elementsEqual(artifacts) else {
                throw AgentError.invariantViolation(
                    "Appended artifact delta does not match the resulting snapshot."
                )
            }
            for artifact in artifacts {
                try validateAndAdd(
                    artifact,
                    sessionID: snapshot.sessionID,
                    totalArtifactBytes: &totalArtifactBytes,
                    artifactIDs: &artifactIDs
                )
            }
            artifactCount = snapshot.artifacts.count

        case .replace(let artifacts):
            guard snapshot.artifacts.elementsEqual(artifacts) else {
                throw AgentError.invariantViolation(
                    "Replacement artifact delta does not match the resulting snapshot."
                )
            }
            artifactIDs.removeAll(keepingCapacity: true)
            totalArtifactBytes = 0
            for artifact in artifacts {
                try validateAndAdd(
                    artifact,
                    sessionID: snapshot.sessionID,
                    totalArtifactBytes: &totalArtifactBytes,
                    artifactIDs: &artifactIDs
                )
            }
            artifactCount = artifacts.count
        }

        return RuntimeSessionValidationIndex(
            sessionID: snapshot.sessionID,
            revision: snapshot.revision,
            messageCount: messageCount,
            leadingSystemMessageCount: leadingSystemMessageCount,
            toolCallsByID: toolCallsByID,
            artifactCount: artifactCount,
            artifactIDs: artifactIDs,
            totalArtifactBytes: totalArtifactBytes
        )
    }

    private func validateEnvelope(
        snapshot: SessionSnapshot,
        checkpointPrefixValidation: Bool
    ) throws {
        try snapshot.validateState(
            checkpointPrefixValidation: checkpointPrefixValidation
        )
        try validateIdentifier(snapshot.sessionID, field: "session identifier")
        try validateDate(snapshot.createdAt, field: "session createdAt")
        try validateDate(snapshot.updatedAt, field: "session updatedAt")

        guard snapshot.messages.count <= limits.maxTranscriptMessages else {
            throw AgentError.budgetExceeded(
                "Transcript contains \(snapshot.messages.count) messages; limit is \(limits.maxTranscriptMessages)."
            )
        }
        guard snapshot.artifacts.count <= limits.maxSessionArtifacts else {
            throw AgentError.budgetExceeded(
                "Session contains \(snapshot.artifacts.count) artifacts; limit is \(limits.maxSessionArtifacts)."
            )
        }

        if let title = snapshot.title {
            try validateText(title, field: "session title")
        }
        if let providerID = snapshot.providerID {
            try validateIdentifier(providerID, field: "provider identifier")
        }
        if let modelID = snapshot.modelID {
            try validateIdentifier(modelID, field: "model identifier")
        }
        try validateMetadata(snapshot.metadata, field: "session metadata")
        if let checkpoint = snapshot.contextCheckpoint {
            try validate(
                message: checkpoint.summaryMessage,
                contentField: "session context checkpoint summary"
            )
        }

        if let waitState = snapshot.waitState {
            try validateIdentifier(waitState.identifier, field: "wait identifier")
            try validateDate(waitState.createdAt, field: "wait createdAt")
            if let resumeAt = waitState.resumeAt {
                try validateDate(resumeAt, field: "wait resumeAt")
            }
            try validateMetadata(waitState.details, field: "wait details \(waitState.identifier)")
        }
        if let failure = snapshot.failure {
            try validateIdentifier(failure.code, field: "session failure code")
            try validateText(
                failure.message,
                field: "session failure message",
                maximumUTF8Bytes: limits.maxFailureMessageUTF8Bytes
            )
            try validateDate(failure.occurredAt, field: "session failure occurredAt")
            try validateMetadata(failure.details, field: "session failure details")
        }
        if let signal = snapshot.lastSignal {
            try validateIdentifier(signal.identifier, field: "signal identifier")
            try validateDate(signal.receivedAt, field: "signal receivedAt")
            try validateSignalPayload(signal.payload)
        }
    }

    private func addToolCalls(
        _ calls: [ToolCall],
        sessionID: String,
        to toolCallsByID: inout [String: ToolCall]
    ) throws {
        for call in calls {
            if let existing = toolCallsByID[call.id], existing != call {
                throw AgentError.invariantViolation(
                    "Session \(sessionID) reuses tool call identifier \(call.id) for a different call."
                )
            }
            toolCallsByID[call.id] = call
        }
    }

    private func validateAndAdd(
        _ artifact: ArtifactRecord,
        sessionID: String,
        totalArtifactBytes: inout Int,
        artifactIDs: inout Set<String>
    ) throws {
        guard artifact.sessionID == sessionID else {
            throw AgentError.invariantViolation(
                "Artifact \(artifact.id) belongs to \(artifact.sessionID), not session \(sessionID)."
            )
        }
        try validate(artifactRecord: artifact)
        guard artifactIDs.insert(artifact.id).inserted else {
            throw AgentError.invariantViolation(
                "Session \(sessionID) contains duplicate artifact identifier \(artifact.id)."
            )
        }
        guard artifact.byteCount <= limits.maxSessionArtifactBytes - totalArtifactBytes else {
            throw AgentError.budgetExceeded(
                "Session artifact bytes exceed \(limits.maxSessionArtifactBytes)."
            )
        }
        totalArtifactBytes += artifact.byteCount
    }

    func validate(turn: ModelTurn) throws {
        try validateText(turn.content, field: "model turn content")
        try validateContentParts(turn.contentParts, field: "model turn content")
        try validateMetadata(turn.metadata, field: "model turn metadata")
        try validateToolCalls(turn.toolCalls)
        if let responseID = turn.responseID {
            try validateIdentifier(responseID, field: "model response identifier")
        }
        if let reasoningSummary = turn.reasoningSummary {
            try validateText(reasoningSummary, field: "model reasoning summary")
        }
        if let usage = turn.usage {
            try validate(usage: usage)
        }
    }

    func validate(result: ToolResult) throws {
        try validateIdentifier(result.callID, field: "tool result call identifier")
        try validateIdentifier(result.toolName, field: "tool result name")
        try validateJSON(
            result.output,
            field: "tool result output \(result.callID)",
            maximumCanonicalUTF8Bytes: limits.maxMessageUTF8Bytes
        )
        try validateText(result.renderedContent, field: "tool result \(result.callID)")
        try validateMetadata(result.metadata, field: "tool result metadata \(result.callID)")

        guard result.artifacts.count <= limits.maxArtifactsPerToolResult else {
            throw AgentError.budgetExceeded(
                "Tool result contains \(result.artifacts.count) artifacts; limit is \(limits.maxArtifactsPerToolResult)."
            )
        }
        var totalArtifactBytes = 0
        for artifact in result.artifacts {
            try validate(artifact: artifact)
            guard artifact.data.count <= limits.maxSessionArtifactBytes - totalArtifactBytes else {
                throw AgentError.budgetExceeded(
                    "Tool result artifact bytes exceed \(limits.maxSessionArtifactBytes)."
                )
            }
            totalArtifactBytes += artifact.data.count
        }
    }

    func validate(artifact: ArtifactWriteRequest) throws {
        try validateIdentifier(artifact.preferredFilename, field: "artifact filename")
        try validateIdentifier(artifact.mimeType, field: "artifact MIME type")
        guard artifact.data.count <= limits.maxArtifactBytes else {
            throw AgentError.budgetExceeded(
                "Artifact \(artifact.preferredFilename) contains \(artifact.data.count) bytes; limit is \(limits.maxArtifactBytes)."
            )
        }
        try validateMetadata(
            artifact.metadata,
            field: "artifact metadata \(artifact.preferredFilename)"
        )
    }

    private func validate(message: AgentMessage, contentField: String) throws {
        try validateIdentifier(message.id, field: "message identifier")
        try validateDate(message.createdAt, field: "message createdAt \(message.id)")
        try validateText(message.content, field: contentField)
        try validateContentParts(message.contentParts, field: contentField)
        if let toolCallID = message.toolCallID {
            try validateIdentifier(toolCallID, field: "message tool call identifier")
        }
        if let toolName = message.toolName {
            try validateIdentifier(toolName, field: "message tool name")
        }
        try validateMetadata(message.metadata, field: "message metadata \(message.id)")
        try validateToolCalls(message.toolCalls)
    }

    private func validateContentParts(
        _ parts: [ModelContentPart],
        field: String
    ) throws {
        var binaryBytes = 0
        for part in parts {
            switch part {
            case let .text(value):
                try validateText(value, field: "\(field) text part")
            case let .image(binary), let .audio(binary), let .file(binary):
                try validateIdentifier(binary.mimeType, field: "\(field) MIME type")
                if let filename = binary.filename {
                    try validateText(filename, field: "\(field) filename")
                }
                guard binary.data.count <= limits.maxMessageUTF8Bytes - binaryBytes else {
                    throw AgentError.budgetExceeded(
                        "\(field) binary content exceeds maxMessageUTF8Bytes."
                    )
                }
                binaryBytes += binary.data.count
            }
        }
    }

    private func validate(usage: ModelUsage) throws {
        let values = [usage.inputTokens, usage.outputTokens, usage.totalTokens]
        guard values.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw AgentError.invariantViolation("Model usage token counts must not be negative.")
        }
    }

    private func validate(artifactRecord artifact: ArtifactRecord) throws {
        try validateIdentifier(artifact.id, field: "artifact identifier")
        try validateIdentifier(artifact.sessionID, field: "artifact session identifier")
        try validateIdentifier(artifact.filename, field: "artifact filename")
        try validateIdentifier(artifact.relativePath, field: "artifact relative path")
        try validateIdentifier(artifact.mimeType, field: "artifact MIME type")
        try validateDate(artifact.createdAt, field: "artifact createdAt \(artifact.id)")
        guard artifact.byteCount >= 0,
              artifact.byteCount <= limits.maxArtifactBytes else {
            throw AgentError.budgetExceeded(
                "Artifact record \(artifact.id) contains \(artifact.byteCount) bytes; limit is \(limits.maxArtifactBytes)."
            )
        }
        try validateMetadata(artifact.metadata, field: "artifact metadata \(artifact.id)")
    }

    private func validateToolCalls(_ calls: [ToolCall]) throws {
        guard calls.count <= limits.maxToolCallsPerTurn else {
            throw AgentError.budgetExceeded(
                "Model turn contains \(calls.count) tool calls; limit is \(limits.maxToolCallsPerTurn)."
            )
        }

        var callIDs: Set<String> = []
        for call in calls {
            try validateIdentifier(call.id, field: "tool call identifier")
            guard ModelToolContract.isValidName(call.name) else {
                throw AgentError.invariantViolation(
                    "Tool call name violates the model tool contract: \(call.name)"
                )
            }
            try validateIdentifier(call.name, field: "tool call name")
            guard callIDs.insert(call.id).inserted else {
                throw AgentError.invariantViolation(
                    "Model turn contains duplicate tool call identifier \(call.id)."
                )
            }
            try validateJSON(
                call.arguments,
                field: "tool arguments for \(call.name)",
                maximumCanonicalUTF8Bytes: limits.maxToolArgumentsUTF8Bytes
            )
            try validateMetadata(
                call.metadata,
                field: "tool metadata for \(call.name)"
            )
        }
    }

    private func validateMetadata(
        _ metadata: [String: JSONValue],
        field: String
    ) throws {
        try validateJSON(
            .object(metadata),
            field: field,
            maximumCanonicalUTF8Bytes: limits.maxToolArgumentsUTF8Bytes
        )
    }

    private func validateJSON(
        _ value: JSONValue,
        field: String,
        maximumCanonicalUTF8Bytes: Int
    ) throws {
        do {
            try value.validateStructure(limits: jsonStructureLimits)
        } catch let error as JSONValueStructureError {
            throw AgentError.budgetExceeded("\(field): \(error.localizedDescription)")
        }

        let byteCount = try value.canonicalUTF8ByteCount()
        guard byteCount <= maximumCanonicalUTF8Bytes else {
            throw AgentError.budgetExceeded(
                "\(field) contains \(byteCount) canonical UTF-8 bytes; limit is \(maximumCanonicalUTF8Bytes)."
            )
        }
    }

    func validateFailureReason(_ reason: String) throws {
        try validateText(
            reason,
            field: "failure reason",
            maximumUTF8Bytes: limits.maxFailureMessageUTF8Bytes
        )
    }

    private func validateIdentifier(_ value: String, field: String) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invariantViolation("\(field) must not be empty.")
        }
        try validateText(
            value,
            field: field,
            maximumUTF8Bytes: limits.maxIdentifierUTF8Bytes
        )
    }

    private func validateDate(_ value: Date, field: String) throws {
        let referenceInterval = value.timeIntervalSinceReferenceDate
        let milliseconds = value.timeIntervalSince1970 * 1_000
        guard referenceInterval.isFinite,
              milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            throw AgentError.invariantViolation("\(field) is outside the supported date range.")
        }
    }

    private func validateText(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int? = nil
    ) throws {
        let limit = maximumUTF8Bytes ?? limits.maxMessageUTF8Bytes
        let byteCount = value.utf8.count
        guard byteCount <= limit else {
            throw AgentError.budgetExceeded(
                "\(field) contains \(byteCount) UTF-8 bytes; limit is \(limit)."
            )
        }
    }
}
