import Foundation

public enum ASKJSONToolMode: String, Codable, Equatable, Sendable {
    case readOnly = "read_only"
    case ingest
    case planning
}

public struct ASKJSONFieldDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var typeDescription: String
    public var required: Bool

    public init(name: String, typeDescription: String, required: Bool) {
        self.name = name
        self.typeDescription = typeDescription
        self.required = required
    }
}

public struct ASKJSONToolDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var mode: ASKJSONToolMode
    public var summary: String
    public var requestFields: [ASKJSONFieldDescriptor]
    public var responseType: String

    public init(name: String, mode: ASKJSONToolMode, summary: String, requestFields: [ASKJSONFieldDescriptor], responseType: String) {
        self.name = name
        self.mode = mode
        self.summary = summary
        self.requestFields = requestFields
        self.responseType = responseType
    }
}

public struct ASKJSONBridgeContract: Codable, Equatable, Sendable {
    public var version: String
    public var tools: [ASKJSONToolDescriptor]

    public init(version: String, tools: [ASKJSONToolDescriptor]) {
        self.version = version
        self.tools = tools
    }

    public func tool(named name: String) -> ASKJSONToolDescriptor? {
        tools.first { $0.name == name }
    }
}

public enum ASKJSONBridgeSchema {
    public static let version = "ask-json-bridge.v1"

    public static let current = ASKJSONBridgeContract(
        version: version,
        tools: [
            ASKJSONToolDescriptor(name: "ask.contract", mode: .readOnly, summary: "Describe the stable ASK JSON bridge contract.", requestFields: [], responseType: "ASKJSONBridgeContract"),
            ASKJSONToolDescriptor(name: "ask.state.summary", mode: .readOnly, summary: "Return aggregate vault counts without exposing internal records.", requestFields: [], responseType: "ASKStateSummary"),
            ASKJSONToolDescriptor(name: "ask.search", mode: .readOnly, summary: "Search the local ASK vault.", requestFields: [ASKJSONFieldDescriptor(name: "query", typeDescription: "string", required: true), ASKJSONFieldDescriptor(name: "limit", typeDescription: "integer", required: false)], responseType: "SearchResult"),
            ASKJSONToolDescriptor(name: "ask.read_projection", mode: .readOnly, summary: "Read a visible projection document by slug.", requestFields: [ASKJSONFieldDescriptor(name: "slug", typeDescription: "string", required: true)], responseType: "ProjectionDocument?"),
            ASKJSONToolDescriptor(name: "ask.query", mode: .readOnly, summary: "Answer from grounded local projections and evidence.", requestFields: [ASKJSONFieldDescriptor(name: "question", typeDescription: "string", required: true), ASKJSONFieldDescriptor(name: "requested_at", typeDescription: "RFC3339 string", required: true), ASKJSONFieldDescriptor(name: "file_back_slug", typeDescription: "string", required: false)], responseType: "QueryResult"),
            ASKJSONToolDescriptor(name: "ask.review_queue", mode: .readOnly, summary: "Return pending review items.", requestFields: [], responseType: "ReviewQueueResult"),
            ASKJSONToolDescriptor(name: "ask.pending_patches", mode: .readOnly, summary: "Return pending staged patch plans.", requestFields: [], responseType: "[KnowledgePatchPlan]"),
            ASKJSONToolDescriptor(name: "ask.read_patch", mode: .readOnly, summary: "Read a staged patch plan by patch id.", requestFields: [ASKJSONFieldDescriptor(name: "patch_id", typeDescription: "string", required: true)], responseType: "KnowledgePatchPlan?"),
            ASKJSONToolDescriptor(name: "ask.lint", mode: .readOnly, summary: "Return structural lint findings.", requestFields: [], responseType: "LintResult"),
            ASKJSONToolDescriptor(name: "ask.import_collected", mode: .ingest, summary: "Import a staged collected capture into the vault.", requestFields: [ASKJSONFieldDescriptor(name: "manifest_path", typeDescription: "absolute or relative path string", required: true)], responseType: "ASKImportedCapture"),
            ASKJSONToolDescriptor(name: "ask.plan_evidence_ingest", mode: .planning, summary: "Plan an ingest patch from a validated evidence request.", requestFields: [ASKJSONFieldDescriptor(name: "request", typeDescription: "IngestEvidenceRequest", required: true)], responseType: "IngestEvidenceOutcome"),
            ASKJSONToolDescriptor(name: "ask.verify", mode: .planning, summary: "Verify a patch plan without applying it.", requestFields: [ASKJSONFieldDescriptor(name: "plan", typeDescription: "KnowledgePatchPlan", required: true)], responseType: "VerificationReport"),
        ]
    )

}
