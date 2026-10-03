import ASK
import ASKMCP
import Foundation
import MCP
import Testing

@testable import ASKMCP

@Suite("ASKMCP write policy")
struct ASKMCPPolicyTests {
    private func makeDispatcher(policy: ASKMCPPolicy, operatorIdentity: String? = nil) throws -> ASKMCPRequestDispatcher {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return try ASKMCPRequestDispatcher(
            configuration: ASKConfiguration(workspaceURL: workspace),
            catalog: try ASKMCPToolCatalog(policy: policy),
            policyConfiguration: ASKMCPPolicyConfiguration(policy: policy, operatorIdentity: operatorIdentity)
        )
    }

    @Test func readOnlyExposesOnlyQueries() throws {
        let catalog = try ASKMCPToolCatalog(policy: .readOnly)
        #expect(Set(catalog.tools.map(\.name)) == ASKToolSurface.queryTools)
    }

    @Test func stagingExposesExecutableProposalAndRecoveryToolsButNoCommitWorkflow() throws {
        let catalog = try ASKMCPToolCatalog(policy: .staging)
        let names = Set(catalog.tools.map(\.name))
        #expect(names.contains("stage_report"))
        #expect(names.contains("rebuild_knowledge"))
        #expect(names.contains("record_decision_memory"))
        #expect(names.isDisjoint(with: ASKToolSurface.bundledCommitTools))
    }

    @Test func fullModeInjectsExternalOperatorIdentityWithoutInBandConfirmation() {
        let result = ASKMCPRequestDispatcher.approvalGate(
            forTool: "decide_patch",
            dryRunOnly: false,
            envelope: [
                "patchID": .string("p1"),
                "decidedBy": .string("model-value"),
            ],
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .full, operatorIdentity: "human-op")
        )
        guard case .success(let envelope) = result,
              case .string(let decidedBy)? = envelope["decidedBy"] else {
            Issue.record("external operator identity must authorize the call")
            return
        }
        #expect(decidedBy == "human-op")
        #expect(envelope["confirmHumanApproval"] == nil)
    }

    @Test func fullModeRejectsCommitWithoutExternalOperatorIdentity() {
        let result = ASKMCPRequestDispatcher.approvalGate(
            forTool: "decide_patch",
            dryRunOnly: false,
            envelope: [:],
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .full)
        )
        guard case .failure(let diagnostic) = result else {
            Issue.record("missing operator identity must fail")
            return
        }
        #expect(diagnostic.message.contains("ASK_OPERATOR"))
    }

    @Test func operatorIdentityIsOnlyResolvedForFullPolicy() {
        #expect(ASKMCPPolicyConfiguration(policy: .full, operatorIdentity: "op").resolvedOperatorIdentity == "op")
        #expect(ASKMCPPolicyConfiguration(policy: .staging, operatorIdentity: "op").resolvedOperatorIdentity == nil)
        #expect(ASKMCPPolicyConfiguration(policy: .readOnly, operatorIdentity: "op").resolvedOperatorIdentity == nil)
    }
}

extension ASKMCPPolicyTests {
    @Test func captureAuthorizationCoversTheWholeStagingRootNotOnlyItsManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let staging = root.appendingPathComponent("staging")
        let capture = staging.appendingPathComponent(".ask/collector/web/source")
        let manifest = capture.appendingPathComponent("capture_manifest.json")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest)
        let args: [String: MCPJSONValue] = [
            "captureManifestURL": .string(manifest.absoluteString), "domain": .string("notes"),
            "requestedAt": .string("2026-09-06T00:00:00Z"), "dryRunOnly": .bool(true),
        ]
        let leafOnly = try ASKMCPRequestDispatcher(configuration: ASKConfiguration(workspaceURL: workspace),
            catalog: ASKMCPToolCatalog(policy: .staging),
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .staging, additionalReadRoots: [capture]))
        let denied = try await leafOnly.callTool(name: "import_capture", arguments: args)
        #expect(denied.isError)
        guard case .object(let diagnostic)? = denied.structuredContent else {
            Issue.record("Expected structured scope denial"); return
        }
        #expect(diagnostic["code"] == .string("permissionDenied"))
        let fullScope = try ASKMCPRequestDispatcher(configuration: ASKConfiguration(workspaceURL: workspace),
            catalog: ASKMCPToolCatalog(policy: .staging),
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .staging, additionalReadRoots: [staging]))
        #expect(try await fullScope.callTool(name: "import_capture", arguments: args).isError == false)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }
}
