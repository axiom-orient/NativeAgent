import Foundation
import KnowledgeCore
import KnowledgeRuntime

private struct EmptyArgs: Codable {}
private struct SearchArgs: Codable { var query: String; var limit: Int? }
private struct ReadProjectionArgs: Codable { var slug: String }
private struct ReadPatchArgs: Codable { var patchID: String }
private struct QueryArgs: Codable {
    var question: String
    var requestedAt: String
    var fileBackSlug: String?
}
private struct ImportCollectedArgs: Codable {
    var manifestPath: String
}
private struct PlanEvidenceArgs: Codable { var request: IngestEvidenceRequest }
private struct VerifyArgs: Codable { var plan: KnowledgePatchPlan }

extension ASKJSONToolExecutor {
    func dispatch(tool: String, argsJSON: Data = Data("{}".utf8)) throws -> Data {
        if tool == "ask.apply" || tool == "ask.rebuild" {
            throw ASKJSONBridgeError.mutationDenied(tool)
        }
        guard let descriptor = Self.contract.tool(named: tool) else {
            throw ASKJSONBridgeError.unknownTool(tool)
        }

        switch tool {
        case "ask.contract":
            _ = try decodeBridgeArgs(EmptyArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(Self.contract)
        case "ask.state.summary":
            _ = try decodeBridgeArgs(EmptyArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try stateSummary())
        case "ask.search":
            let args = try decodeBridgeArgs(SearchArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try search(args.query, limit: args.limit ?? 8))
        case "ask.read_projection":
            let args = try decodeBridgeArgs(ReadProjectionArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try readProjection(args.slug))
        case "ask.query":
            let args = try decodeBridgeArgs(QueryArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try query(args.question, requestedAt: args.requestedAt, fileBackSlug: args.fileBackSlug))
        case "ask.review_queue":
            _ = try decodeBridgeArgs(EmptyArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try reviewQueue())
        case "ask.pending_patches":
            _ = try decodeBridgeArgs(EmptyArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try pendingPatches())
        case "ask.read_patch":
            let args = try decodeBridgeArgs(ReadPatchArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try readPatch(args.patchID))
        case "ask.lint":
            _ = try decodeBridgeArgs(EmptyArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try lint())
        case "ask.import_collected":
            let args = try decodeBridgeArgs(ImportCollectedArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try importCollected(URL(fileURLWithPath: args.manifestPath)))
        case "ask.plan_evidence_ingest":
            let args = try decodeBridgeArgs(PlanEvidenceArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try planEvidenceIngest(args.request))
        case "ask.verify":
            let args = try decodeBridgeArgs(VerifyArgs.self, tool: tool, descriptor: descriptor, from: argsJSON)
            return try encodeBridgeValue(try verify(args.plan))
        default:
            // The contract lookup above makes this reachable only when dispatch
            // and the published contract drift apart.
            throw ASKJSONBridgeError.unknownTool(tool)
        }
    }
}
