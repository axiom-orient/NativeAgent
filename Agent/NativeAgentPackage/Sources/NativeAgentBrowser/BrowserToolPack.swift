import NativeAgentDomain
import Foundation

#if canImport(WebKit)
public struct BrowserToolPack: ToolPack {
    public let packID: String
    private let session: BrowserSession

    public init(
        session: BrowserSession,
        packID: String = "browser"
    ) throws {
        guard !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidConfiguration("Browser tool pack identifier must not be empty.")
        }
        self.session = session
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        BrowserToolKind.allCases.map {
            BrowserToolExecutor(kind: $0, session: session)
        }
    }
}

private enum BrowserToolKind: String, CaseIterable, Sendable {
    case observe = "browser.observe"
    case navigate = "browser.navigate"
    case click = "browser.click"
    case type = "browser.type"
    case select = "browser.select"
    case scroll = "browser.scroll"
    case back = "browser.back"
    case forward = "browser.forward"
    case reload = "browser.reload"
    case snapshot = "browser.snapshot"

    var definition: ToolDefinition {
        ToolDefinition(
            name: rawValue,
            description: description,
            capabilityID: .browser,
            inputSchema: inputSchema,
            approvalPolicy: approvalPolicy,
            effect: isReadOnly ? .readOnly : .mutation
        )
    }

    private var description: String {
        switch self {
        case .observe:
            "Observe bounded visible text and semantic interactive elements without page source or secret values."
        case .navigate:
            "Navigate to an absolute URL allowed by the host browser policy, then return a semantic observation."
        case .click:
            "Click a visible semantic element only if the page revision still matches."
        case .type:
            "Replace text in a non-sensitive editable element only if the page revision still matches."
        case .select:
            "Select an existing option value only if the page revision still matches."
        case .scroll:
            "Scroll the page by bounded pixel deltas and return a new semantic observation."
        case .back:
            "Navigate backward in this non-persistent browser session."
        case .forward:
            "Navigate forward in this non-persistent browser session."
        case .reload:
            "Reload the current page."
        case .snapshot:
            "Capture a bounded PNG snapshot as a runtime-owned artifact request."
        }
    }

    private var inputSchema: JSONValue {
        switch self {
        case .observe, .back, .forward, .reload, .snapshot:
            ToolSchema.object(properties: [:])
        case .navigate:
            ToolSchema.object(
                properties: [
                    "url": ToolSchema.string(
                        description: "Absolute policy-allowed URL.",
                        minLength: 1,
                        maxLength: 4_096
                    )
                ],
                required: ["url"]
            )
        case .click:
            revisionSchema(
                properties: [
                    "elementID": ToolSchema.string(description: "Element ID from browser.observe.", minLength: 1, maxLength: 128)
                ],
                required: ["elementID"]
            )
        case .type:
            revisionSchema(
                properties: [
                    "elementID": ToolSchema.string(description: "Editable element ID from browser.observe.", minLength: 1, maxLength: 128),
                    "text": ToolSchema.string(description: "Replacement text. Sensitive and file inputs are always denied.")
                ],
                required: ["elementID", "text"]
            )
        case .select:
            revisionSchema(
                properties: [
                    "elementID": ToolSchema.string(description: "Select element ID from browser.observe.", minLength: 1, maxLength: 128),
                    "value": ToolSchema.string(description: "Existing option value.", maxLength: 65_536)
                ],
                required: ["elementID", "value"]
            )
        case .scroll:
            revisionSchema(
                properties: [
                    "deltaX": ToolSchema.integer(description: "Horizontal pixel delta.", minimum: -100_000, maximum: 100_000),
                    "deltaY": ToolSchema.integer(description: "Vertical pixel delta.", minimum: -100_000, maximum: 100_000)
                ],
                required: ["deltaY"]
            )
        }
    }

    private func revisionSchema(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        var properties = properties
        properties["expectedPageRevision"] = ToolSchema.string(
            description: "Exact revision returned by the latest browser observation.",
            minLength: 1,
            maxLength: 256
        )
        return ToolSchema.object(
            properties: properties,
            required: required + ["expectedPageRevision"]
        )
    }

    private var approvalPolicy: ApprovalPolicy {
        switch self {
        case .observe, .scroll, .snapshot:
            .automatic
        case .navigate, .click, .type, .select, .back, .forward, .reload:
            .requireApproval
        }
    }

    private var isReadOnly: Bool {
        switch self {
        case .observe, .scroll, .snapshot:
            true
        case .navigate, .click, .type, .select, .back, .forward, .reload:
            false
        }
    }
}

private struct BrowserToolExecutor: ToolExecutor {
    let kind: BrowserToolKind
    let session: BrowserSession

    var definition: ToolDefinition { kind.definition }

    func execute(
        call: ToolCall,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        switch kind {
        case .observe:
            let observation = try await session.observe()
            return try observationResult(call: call, observation: observation)
        case .navigate:
            let rawURL = try call.arguments.stringField("url")
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                throw AgentError.invalidToolCall(
                    "browser.navigate accepts only absolute HTTP(S) URLs; local content is host-loaded."
                )
            }
            _ = try await session.navigate(to: url)
            let observation = try await session.observe()
            return try observationResult(call: call, observation: observation)
        case .click:
            let elementID = try call.arguments.stringField("elementID")
            let expectedRevision = try call.arguments.stringField("expectedPageRevision")
            let observation = try await session.click(
                elementID: elementID,
                expectedPageRevision: expectedRevision
            )
            return try observationResult(call: call, observation: observation)
        case .type:
            let text = try call.arguments.stringField("text")
            let elementID = try call.arguments.stringField("elementID")
            let expectedRevision = try call.arguments.stringField("expectedPageRevision")
            let observation = try await session.type(
                text: text,
                into: elementID,
                expectedPageRevision: expectedRevision
            )
            return try observationResult(call: call, observation: observation)
        case .select:
            let value = try call.arguments.stringField("value")
            let elementID = try call.arguments.stringField("elementID")
            let expectedRevision = try call.arguments.stringField("expectedPageRevision")
            let observation = try await session.select(
                value: value,
                in: elementID,
                expectedPageRevision: expectedRevision
            )
            return try observationResult(call: call, observation: observation)
        case .scroll:
            let deltaX = call.arguments.optionalIntField("deltaX") ?? 0
            let deltaY = try call.arguments.intField("deltaY")
            let expectedRevision = try call.arguments.stringField("expectedPageRevision")
            let observation = try await session.scroll(
                deltaX: deltaX,
                deltaY: deltaY,
                expectedPageRevision: expectedRevision
            )
            return try observationResult(call: call, observation: observation)
        case .back:
            _ = try await session.goBack()
            let observation = try await session.observe()
            return try observationResult(call: call, observation: observation)
        case .forward:
            _ = try await session.goForward()
            let observation = try await session.observe()
            return try observationResult(call: call, observation: observation)
        case .reload:
            _ = try await session.reload()
            let observation = try await session.observe()
            return try observationResult(call: call, observation: observation)
        case .snapshot:
            let artifact = try await session.snapshot()
            return ToolResult.text(
                callID: call.id,
                toolName: definition.name,
                content: "Captured a bounded browser snapshot.",
                artifacts: [artifact],
                metadata: ["browserSessionID": .string(session.sessionID)]
            )
        }
    }

    private func observationResult(
        call: ToolCall,
        observation: BrowserObservation
    ) throws -> ToolResult {
        return ToolResult(
            callID: call.id,
            toolName: definition.name,
            output: try JSONValue.encode(observation),
            metadata: [
                "browserSessionID": .string(observation.sessionID),
                "pageRevision": .string(observation.pageRevision)
            ]
        )
    }
}
#endif
