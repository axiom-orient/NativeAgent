import ASK
import ASKMCP
import ASKMCPHTTP
import Foundation
import MCP
import MCPHTTPClient
import Testing

/// Exercises the HTTP transport with swiftMcp's own conforming client: the
/// client generates every required binding header, so a pass proves our server
/// accepts real MCP hosts rather than hand-rolled requests.
@Suite("ASKMCP HTTP transport", .serialized)
struct ASKMCPHTTPTransportTests {
    private func makeConnectedClient(
        workspace: URL
    ) async throws -> (client: MCPClient, running: ASKMCPHTTPServerFactory.RunningServer) {
        let running = try ASKMCPHTTPServerFactory.start(
            configuration: ASKConfiguration(workspaceURL: workspace)
            , policyConfiguration: ASKMCPPolicyConfiguration(
                policy: .full,
                operatorIdentity: "http-test-operator"
            )
        )
        let transport = MCPHTTPClientTransport(
            configuration: try MCPHTTPClientConfiguration(endpoint: running.endpoint)
        )
        let client = try MCPClient(
            transport: transport,
            configuration: MCPClientConfiguration(
                implementation: try MCPImplementation(name: "askmcp-tests", version: "0.0.1"),
                capabilities: MCPClientCapabilities()
            )
        )
        return (client, running)
    }

    @Test func httpRoundTripListsAllContractTools() async throws {
        let workspace = try makeTestWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (client, running) = try await makeConnectedClient(workspace: workspace)
        do {
            let tools = try await client.listTools()
            #expect(tools.tools.count == 24)
            #expect(Set(tools.tools.map(\.name)) == ASKMCPToolCatalog.commandNames.union(ASKMCPToolCatalog.queryNames))
        } catch {
            await running.shutdown()
            throw error
        }
        await running.shutdown()
    }

    @Test func httpCallToolAppliesAndReportsTypedOutcome() async throws {
        let workspace = try makeTestWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (client, running) = try await makeConnectedClient(workspace: workspace)
        do {
            let outcome = try await client.callTool(MCPCallToolParams(
                name: "quick_start",
                arguments: [
                    "requestedAt": .string("2026-08-24T00:00:00Z"),
                    "resetExistingWorkspace": .bool(true),
                ]
            ))
            #expect(!outcome.isError)
            guard case .object(let structured)? = outcome.structuredContent else {
                Issue.record("expected structured content")
                return
            }
            #expect(structured["workspaceApplied"] != nil)
        } catch {
            await running.shutdown()
            throw error
        }
        await running.shutdown()
    }

    @Test func httpRejectsUnknownArgumentsAtTheSchemaBoundary() async throws {
        let workspace = try makeTestWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (client, running) = try await makeConnectedClient(workspace: workspace)
        do {
            _ = try await client.callTool(MCPCallToolParams(
                name: "quick_start",
                arguments: [
                    "requestedAt": .string("2026-08-24T00:00:00Z"),
                    "bogusField": .integer(1),
                ]
            ))
            Issue.record("schema violation must fail")
        } catch {
            #expect(String(describing: error).contains("-32602"), "expected invalid-arguments rejection, got: \(error)")
        }
        await running.shutdown()
    }
}
