import ASK
import Foundation
import KnowledgeCore
import MCP
import Testing

@testable import ASKMCP

func makeTestWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "askmcp-tests-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("ASKMCP tool catalog")
struct ASKMCPToolCatalogTests {
    @Test func catalogExposesCanonicalContractTools() throws {
        let catalog = try ASKMCPToolCatalog()
        #expect(catalog.tools.count == 24)
        let expected = ASKMCPToolCatalog.commandNames.union(ASKMCPToolCatalog.queryNames)
        #expect(Set(catalog.tools.map(\.name)) == expected)
        #expect(catalog.commandToolNames.count == 13)
        #expect(catalog.queryToolNames.count == 11)
    }

    @Test func everyToolInputSchemaIsAClosedObject() throws {
        let catalog = try ASKMCPToolCatalog()
        for tool in catalog.tools {
            let schema = tool.inputSchema
            #expect(schema["type"] == .string("object"), Comment(rawValue: tool.name))
            #expect(schema["additionalProperties"] == .bool(false), Comment(rawValue: tool.name))
            guard let rawRequired = schema["required"],
                  case .array(let required) = rawRequired,
                  let rawProperties = schema["properties"],
                  case .object(let properties) = rawProperties
            else { continue }
            for entry in required {
                guard case .string(let key) = entry else { continue }
                #expect(properties[key] != nil, Comment(rawValue: "\(tool.name): required key \(key)"))
            }
        }
    }

    @Test func everyToolOutputSchemaDeclaresTypedVariants() throws {
        let catalog = try ASKMCPToolCatalog()
        for tool in catalog.tools {
            guard case .array(let variants)? = tool.outputSchema?["oneOf"] else {
                Issue.record("\(tool.name): output schema must declare oneOf variants")
                continue
            }
            #expect(variants.count >= 2, Comment(rawValue: tool.name))
        }
    }

    @Test func commandToolsExposeDryRunOnlyAndQueryToolsDoNot() throws {
        let catalog = try ASKMCPToolCatalog()
        for name in ASKMCPToolCatalog.commandNames {
            let properties = try #require(catalog.tool(named: name)?.inputSchema["properties"])
            guard case .object(let fields) = properties else {
                Issue.record("\(name): properties must be an object")
                continue
            }
            #expect(fields["dryRunOnly"] != nil, Comment(rawValue: name))
        }
        for name in ASKMCPToolCatalog.queryNames {
            let properties = try #require(catalog.tool(named: name)?.inputSchema["properties"])
            guard case .object(let fields) = properties else {
                Issue.record("\(name): properties must be an object")
                continue
            }
            #expect(fields["dryRunOnly"] == nil, Comment(rawValue: name))
        }
    }

    @Test func decidePatchDecisionFieldIsClosedEnum() throws {
        let catalog = try ASKMCPToolCatalog()
        let properties = try #require(catalog.tool(named: "decide_patch")?.inputSchema["properties"])
        guard case .object(let fields) = properties,
              case .object(let decision)? = fields["decision"],
              case .array(let values)? = decision["enum"]
        else {
            Issue.record("decision enum schema missing")
            return
        }
        #expect(Set(values) == [.string("approved"), .string("rejected")])
    }

    @Test func batchDecisionMemorySchemaUsesAnArrayOfRecords() throws {
        let catalog = try ASKMCPToolCatalog()
        let properties = try #require(catalog.tool(named: "record_decision_memories")?.inputSchema["properties"])
        guard case .object(let fields) = properties,
              case .object(let records)? = fields["records"],
              case .string("array")? = records["type"],
              case .object(let item)? = records["items"],
              case .string("object")? = item["type"]
        else {
            Issue.record("record_decision_memories.records must be an array of objects")
            return
        }
        #expect(records["additionalProperties"] == nil)
    }
}

@Suite("ASKMCP request dispatcher")
struct ASKMCPRequestDispatcherTests {
    private func makeDispatcher() throws -> (dispatcher: ASKMCPRequestDispatcher, workspace: URL) {
        let workspace = try makeTestWorkspace()
        let dispatcher = try ASKMCPRequestDispatcher(
            configuration: ASKConfiguration(workspaceURL: workspace),
            catalog: try ASKMCPToolCatalog(policy: .full),
            policyConfiguration: ASKMCPPolicyConfiguration(
                policy: .full,
                operatorIdentity: "test-operator"
            )
        )
        return (dispatcher, workspace)
    }

    private func actionID(from result: MCPCallToolResult) -> String? {
        guard case .object(let payload)? = result.structuredContent,
              case .string(let actionID)? = payload["actionID"]
        else { return nil }
        return actionID
    }

    @Test func dryRunOnlyQuickStartIsDeterministicAndEffectFree() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let arguments: [String: MCPJSONValue] = [
            "requestedAt": .string("2026-08-24T00:00:00Z"),
            "dryRunOnly": .bool(true),
        ]
        let first = try await dispatcher.callTool(name: "quick_start", arguments: arguments)
        let second = try await dispatcher.callTool(name: "quick_start", arguments: arguments)
        #expect(!first.isError)
        #expect(first.structuredContent != nil)
        #expect(actionID(from: first) != nil)
        #expect(actionID(from: first) == actionID(from: second))
        let children = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        #expect(children.isEmpty, "dry-run must not materialize any workspace path")
    }

    @Test func quickStartApplyThenPendingWorkRoundTrip() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let applied = try await dispatcher.callTool(
            name: "quick_start",
            arguments: [
                "requestedAt": .string("2026-08-24T00:00:00Z"),
                "resetExistingWorkspace": .bool(true),
            ]
        )
        #expect(!applied.isError)
        guard case .object(let outcome)? = applied.structuredContent else {
            Issue.record("expected structured apply outcome")
            return
        }
        #expect(outcome["workspaceApplied"] != nil)

        let pending = try await dispatcher.callTool(name: "pending_work", arguments: [:])
        #expect(!pending.isError)
        guard case .object(let pendingEnvelope)? = pending.structuredContent,
              case .object(let pendingPayload)? = pendingEnvelope["pendingWork"]
        else {
            Issue.record("expected structured pending work")
            return
        }
        #expect(pendingPayload["patches"] != nil)
        #expect(pendingPayload["presentationRepairs"] != nil)

        let health = try await dispatcher.callTool(name: "storage_health", arguments: [:])
        #expect(!health.isError)
    }

    @Test func typedDiagnosticFailureSurfacesAsIsErrorResult() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let failed = try await dispatcher.callTool(
            name: "decide_patch",
            arguments: [
                "patchID": .string("missing-patch"),
                "decision": .string("approved"),
                "decidedAt": .string("2026-08-24T00:00:01Z"),
                "reason": .string("probe"),
            ]
        )
        #expect(failed.isError)
        guard case .object(let diagnostic)? = failed.structuredContent else {
            Issue.record("expected structured typed diagnostic")
            return
        }
        #expect(diagnostic["message"] != nil)
        #expect(diagnostic["message"] != nil)
    }

    @Test func malformedCommandAndQueryArgumentsReturnTypedDiagnostics() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let malformedCommand = try await dispatcher.callTool(
            name: "quick_start",
            arguments: [:]
        )
        #expect(malformedCommand.isError)
        guard case .object(let commandDiagnostic)? = malformedCommand.structuredContent else {
            Issue.record("expected typed command decoding diagnostic")
            return
    }
        #expect(commandDiagnostic["code"] == .string("invalidRequest"))
        #expect(commandDiagnostic["operation"] == .string("apply"))

        let malformedQuery = try await dispatcher.callTool(
            name: "search_evidence",
            arguments: ["limit": .string("not-an-integer")]
        )
        #expect(malformedQuery.isError)
        guard case .object(let queryDiagnostic)? = malformedQuery.structuredContent else {
            Issue.record("expected typed query decoding diagnostic")
            return
    }
        #expect(queryDiagnostic["code"] == .string("invalidRequest"))
        #expect(queryDiagnostic["operation"] == .string("query"))
    }

    @Test func unknownToolIsRejectedWithInvalidParams() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            _ = try await dispatcher.callTool(name: "nonexistent_tool", arguments: [:])
            Issue.record("unknown tool must throw")
        } catch let error as MCPRPCError {
            #expect(error.code.int64Value == -32602)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func dispatcherCannotCallAFilteredOutCatalogTool() async throws {
        let workspace = try makeTestWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dispatcher = try ASKMCPRequestDispatcher(
            configuration: ASKConfiguration(workspaceURL: workspace),
            catalog: ASKMCPToolCatalog(policy: .readOnly),
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .full)
        )

        await #expect(throws: MCPRPCError.self) {
            _ = try await dispatcher.callTool(name: "record_decision_memories", arguments: [:])
        }
    }

    @Test func injectedBudgetDefaultsMatchCoreContextBudgetDefaults() throws {
        let envelope = ASKMCPRequestDispatcher.normalizedEnvelope(
            forTool: "decision_memory",
            arguments: ["frame": MCPJSONValue.object([:])]
        )
        guard let rawBudget = envelope["budget"],
              case .object(let budgetArguments) = rawBudget
        else {
            Issue.record("budget default missing")
            return
        }
        let data = try MCPJSONValue.object(budgetArguments).encoded()
        let decoded = try JSONDecoder().decode(ContextBudget.self, from: data)
        #expect(decoded == ContextBudget())
    }

    @Test func batchDecisionMemoriesDispatchesToTheCanonicalCommand() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let record = MemoryRecord(
            recordID: "mem_batch_001",
            kind: .constraint,
            subject: MemorySubject(kind: "package", subjectID: "askmcp"),
            scope: MemoryScope(workspaceID: "askmcp"),
            statement: "Batch decision-memory dispatch is canonical.",
            priority: 80,
            blocking: true,
            createdAt: "2026-08-24T00:00:00Z"
        )
        let result = try await dispatcher.callTool(
            name: "record_decision_memories",
            arguments: [
                "records": .array([try ASKMCPJSONBridge.structuredValue(record)])
            ]
        )

        #expect(!result.isError)
        guard case .object(let outcome)? = result.structuredContent,
              case .object(let mutation)? = outcome["decisionMemory"]
        else {
            Issue.record("expected decision-memory mutation result")
            return
        }
        #expect(mutation["recordCount"] == .integer(1))
    }
    @Test func mcpCannotExpandManagedWorkspaceRoutes() async throws {
        let (dispatcher, workspace) = try makeDispatcher()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmcp-outside-\(UUID().uuidString)", isDirectory: true)
        let result = try await dispatcher.callTool(
            name: "storage_health",
            arguments: [
                "workspace": .object(["workspaceURL": .string(outside.absoluteString)])
            ]
        )
        #expect(result.isError)
        guard case .object(let diagnostic)? = result.structuredContent else {
            Issue.record("expected resource-scope diagnostic")
            return
        }
        #expect(diagnostic["code"] == .string("permissionDenied"))
    }

    @Test func externalSourceReadRequiresHostApprovedRoot() async throws {
        let workspace = try makeTestWorkspace()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmcp-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let dispatcher = try ASKMCPRequestDispatcher(
            configuration: ASKConfiguration(workspaceURL: workspace),
            catalog: try ASKMCPToolCatalog(policy: .staging),
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .staging)
        )
        let rejected = try await dispatcher.callTool(
            name: "index_workspace",
            arguments: ["sourceRootURL": .string(source.absoluteString)]
        )
        #expect(rejected.isError)
        guard case .object(let diagnostic)? = rejected.structuredContent else {
            Issue.record("expected resource-scope diagnostic")
            return
        }
        #expect(diagnostic["code"] == .string("permissionDenied"))
    }

}
