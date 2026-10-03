import NativeAgentBrowser
import NativeAgentDomain
import Foundation

#if canImport(WebKit)
/// Optional host-supplied structural inspection for an exported rendered DOM.
/// The inspector is deliberately generic so NativeAgent remains independent from any
/// particular HTML parser package.
public struct RenderedHTMLInspector: Sendable {
    private let body: @Sendable (String) throws -> JSONValue

    public init(_ body: @escaping @Sendable (String) throws -> JSONValue) {
        self.body = body
    }

    public func inspect(renderedHTML: String) throws -> JSONValue {
        try body(renderedHTML)
    }
}

/// Opt-in tools for HTML the agent creates for the user. Register this pack
/// together with `BrowserToolPack` when the agent also needs semantic
/// observe/click/type actions. The default browser pack intentionally does not
/// expose page source or arbitrary JavaScript.
public struct InteractiveHTMLToolPack: ToolPack {
    public let packID: String
    private let session: BrowserSession
    private let inspector: RenderedHTMLInspector?

    public init(
        session: BrowserSession,
        inspector: RenderedHTMLInspector? = nil,
        packID: String = "interactive-html"
    ) throws {
        guard !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidConfiguration("Interactive HTML tool pack identifier must not be empty.")
        }
        self.session = session
        self.inspector = inspector
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        InteractiveHTMLToolKind.allCases.map {
            InteractiveHTMLToolExecutor(kind: $0, session: session, inspector: inspector)
        }
    }
}

private enum InteractiveHTMLToolKind: String, CaseIterable, Sendable {
    case presentHTML = "browser.presentHTML"
    case evaluateJavaScript = "browser.evaluateJavaScript"
    case exportHTML = "browser.exportHTML"

    var definition: ToolDefinition {
        ToolDefinition(
            name: rawValue,
            description: description,
            capabilityID: .browser,
            inputSchema: inputSchema,
            approvalPolicy: .requireApproval,
            effect: .mutation,
            metadata: ["interactiveHTML": .bool(true)]
        )
    }

    private var description: String {
        switch self {
        case .presentHTML:
            "Replace the current generated page with bounded HTML only when the observed page revision still matches."
        case .evaluateJavaScript:
            "Run bounded page-world JavaScript equivalent to the host browser evaluation API. JSON object arguments are available as payload; return JSON only."
        case .exportHTML:
            "Export the current rendered DOM as a runtime-owned text/html artifact. This is not the original network response or a canvas pixel capture."
        }
    }

    private var inputSchema: JSONValue {
        switch self {
        case .presentHTML:
            ToolSchema.object(
                properties: [
                    "html": ToolSchema.string(
                        description: "Complete generated HTML document.",
                        minLength: 1,
                        maxLength: 16 * 1_024 * 1_024
                    ),
                    "baseURL": ToolSchema.string(
                        description: "Optional HTTP(S) base URL that the host browser policy explicitly permits.",
                        minLength: 1,
                        maxLength: 4_096
                    ),
                    "expectedPageRevision": revisionSchema
                ],
                required: ["html", "expectedPageRevision"]
            )
        case .evaluateJavaScript:
            ToolSchema.object(
                properties: [
                    "source": ToolSchema.string(
                        description: "JavaScript body. Use return for the JSON-serializable result; payload contains the supplied JSON object.",
                        minLength: 1,
                        maxLength: 1 * 1_024 * 1_024
                    ),
                    "arguments": ToolSchema.object(
                        properties: [:],
                        additionalProperties: true,
                        description: "JSON object exposed to JavaScript as payload."
                    ),
                    "expectedPageRevision": revisionSchema
                ],
                required: ["source", "expectedPageRevision"]
            )
        case .exportHTML:
            ToolSchema.object(
                properties: [
                    "preferredFilename": ToolSchema.string(
                        description: "Optional filename for the exported HTML artifact.",
                        minLength: 1,
                        maxLength: 128
                    ),
                    "expectedPageRevision": revisionSchema
                ],
                required: ["expectedPageRevision"]
            )
        }
    }

    private var revisionSchema: JSONValue {
        ToolSchema.string(
            description: "Exact revision returned by the latest browser observation.",
            minLength: 1,
            maxLength: 256
        )
    }
}

private struct InteractiveHTMLToolExecutor: ToolExecutor {
    let kind: InteractiveHTMLToolKind
    let session: BrowserSession
    let inspector: RenderedHTMLInspector?

    var definition: ToolDefinition { kind.definition }

    func execute(
        call: ToolCall,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        switch kind {
        case .presentHTML:
            let html = try call.arguments.stringField("html")
            let expectedPageRevision = try call.arguments.stringField("expectedPageRevision")
            let baseURL = try baseURL(from: call.arguments.optionalStringField("baseURL"))
            let observation = try await session.presentHTML(
                html,
                baseURL: baseURL,
                expectedPageRevision: expectedPageRevision
            )
            return try observationResult(call: call, observation: observation)

        case .evaluateJavaScript:
            let source = try call.arguments.stringField("source")
            let expectedPageRevision = try call.arguments.stringField("expectedPageRevision")
            let arguments = call.arguments.objectValue?["arguments"] ?? .object([:])
            guard arguments.objectValue != nil else {
                throw AgentError.invalidToolCall("browser.evaluateJavaScript arguments must be a JSON object.")
            }
            let evaluation = try await session.evaluateJavaScript(
                source,
                arguments: arguments,
                expectedPageRevision: expectedPageRevision
            )
            return ToolResult(
                callID: call.id,
                toolName: definition.name,
                output: .object([
                    "result": evaluation.result,
                    "observation": try JSONValue.encode(evaluation.observation)
                ]),
                metadata: metadata(
                    sessionID: evaluation.observation.sessionID,
                    pageRevision: evaluation.observation.pageRevision
                )
            )

        case .exportHTML:
            let expectedPageRevision = try call.arguments.stringField("expectedPageRevision")
            let export = try await session.exportRenderedHTML(
                expectedPageRevision: expectedPageRevision
            )
            let inspection = try inspector?.inspect(renderedHTML: export.html)
            let artifact = ArtifactWriteRequest(
                preferredFilename: call.arguments.optionalStringField("preferredFilename") ?? "interactive.html",
                mimeType: "text/html",
                data: Data(export.html.utf8),
                metadata: [
                    "contentKind": .string("renderedDOM"),
                    "contentSHA256": .string(export.contentSHA256),
                    "pageRevision": .string(export.pageRevision)
                ]
            )
            var output: [String: JSONValue] = [
                "kind": .string("renderedDOM"),
                "byteCount": .integer(Int64(artifact.data.count)),
                "contentSHA256": .string(export.contentSHA256),
                "pageRevision": .string(export.pageRevision)
            ]
            if let inspection {
                output["inspection"] = inspection
            }
            return ToolResult(
                callID: call.id,
                toolName: definition.name,
                output: .object(output),
                artifacts: [artifact],
                metadata: metadata(sessionID: export.sessionID, pageRevision: export.pageRevision)
            )
        }
    }

    private func observationResult(
        call: ToolCall,
        observation: BrowserObservation
    ) throws -> ToolResult {
        ToolResult(
            callID: call.id,
            toolName: definition.name,
            output: try JSONValue.encode(observation),
            metadata: metadata(sessionID: observation.sessionID, pageRevision: observation.pageRevision)
        )
    }

    private func baseURL(from value: String?) throws -> URL? {
        guard let value else { return nil }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw AgentError.invalidToolCall(
                "browser.presentHTML baseURL accepts only absolute HTTP(S) URLs; it cannot read local files."
            )
        }
        return url
    }

    private func metadata(sessionID: String, pageRevision: String) -> [String: JSONValue] {
        [
            "browserSessionID": .string(sessionID),
            "pageRevision": .string(pageRevision),
            "contentProfile": .string("interactiveHTML")
        ]
    }
}
#endif
