import Foundation
import NativeAgentDomain

struct AgentLoopRequestBuilder: Sendable {
    let outputFormat: ModelOutputFormat
    let systemPromptOverride: AgentMessage?
    let userPromptOverride: AgentMessage?

    init(outputFormat: ModelOutputFormat = .text, systemPromptOverride: AgentMessage? = nil, userPromptOverride: AgentMessage? = nil) {
        self.outputFormat = outputFormat
        self.systemPromptOverride = systemPromptOverride
        self.userPromptOverride = userPromptOverride
    }

    func effectiveRequestMetadata(snapshot: SessionSnapshot) -> [String: JSONValue] {
        guard let latestUserMessage = latestUserMessage(in: snapshot.messages),
              latestUserMessage.metadata.isEmpty == false else {
            return snapshot.metadata
        }

        var metadata = snapshot.metadata
        metadata.merge(latestUserMessage.metadata) { _, new in new }
        return metadata
    }

    func makeRequest(
        snapshot: SessionSnapshot,
        messages: [AgentMessage]? = nil,
        tools: [ToolDefinition]
    ) -> ModelRequest {
        ModelRequest(
            sessionID: snapshot.sessionID,
            modelID: snapshot.modelID,
            messages: applyingTurnPrompt(to: messages ?? snapshot.messages),
            tools: tools.map(\.modelTool),
            metadata: effectiveRequestMetadata(snapshot: snapshot),
            outputFormat: outputFormat
        )
    }

    private func applyingTurnPrompt(to messages: [AgentMessage]) -> [AgentMessage] {
        let rendered = messages.map { message in
            if let userPromptOverride, message.id == userPromptOverride.id { return userPromptOverride }
            return message
        }
        guard let systemPromptOverride else { return rendered }
        return [systemPromptOverride] + rendered.drop(while: { $0.role == .system })
    }

    func makeProjection(
        snapshot: SessionSnapshot,
        messages: [AgentMessage],
        tools: [ToolDefinition],
        checkpointApplied: Bool
    ) throws -> ContextProjection {
        let request = makeRequest(snapshot: snapshot, messages: messages, tools: tools)
        let footprint = try request.inputFootprint()
        return try ContextProjection(
            snapshot: snapshot,
            request: request,
            footprint: footprint,
            checkpointApplied: checkpointApplied
        )
    }

    func requiresHardCompaction(
        snapshot: SessionSnapshot,
        messages: [AgentMessage],
        tools: [ToolDefinition]
    ) throws -> Bool {
        let request = makeRequest(snapshot: snapshot, messages: messages, tools: tools)
        do {
            _ = try request.inputFootprint()
            return false
        } catch let failure as ModelGenerationFailure {
            let transcriptPressure =
                request.messages.count > request.limits.maxMessages
                || failure.code == .limitExceeded
            guard transcriptPressure, messages.count > 1 else {
                throw failure
            }

            // The top-level message-count guard fires before per-message
            // validation. Validate every source message independently so a
            // malformed historical message cannot be hidden inside a summary.
            for message in messages {
                let sourceRequest = ModelRequest(
                    sessionID: request.sessionID,
                    modelID: request.modelID,
                    messages: [message],
                    tools: [],
                    metadata: [:],
                    requiredCapabilities: request.requiredCapabilities,
                    outputFormat: request.outputFormat,
                    maxOutputBytes: request.maxOutputBytes,
                    deadline: request.deadline,
                    limits: request.limits
                )
                do {
                    _ = try sourceRequest.inputFootprint()
                } catch let sourceFailure as ModelGenerationFailure
                    where sourceFailure.code == .invalidRequest
                {
                    throw sourceFailure
                } catch {
                    // Historical size pressure is exactly what compaction may
                    // resolve; structural failures are not.
                }
            }

            // Do not persist a lossy transcript compaction for a limit failure
            // caused solely by tools, metadata, or the newest message. Removing
            // history must make the same request contract valid before compaction
            // is allowed to create a durable checkpoint.
            let minimalRequest = makeRequest(
                snapshot: snapshot,
                messages: [messages[messages.index(before: messages.endIndex)]],
                tools: tools
            )
            do {
                _ = try minimalRequest.inputFootprint()
                return true
            } catch {
                throw failure
            }
        }
    }

    private func latestUserMessage(in messages: [AgentMessage]) -> AgentMessage? {
        for message in messages.reversed() where message.role == .user {
            return message
        }
        return nil
    }
}
