import ASK
import ASKMCP
import Foundation
import MCP
import MCPHTTPServer

/// Assembles the request-stateless ASK MCP server behind a loopback HTTP endpoint.
/// Each POST is one independent protocol exchange. Durable ASK workspace state
/// remains owned by ASK storage and is intentionally visible to later requests.
public enum ASKMCPHTTPServerFactory {
    public struct RunningServer: Sendable {
        public let endpoint: URL
        private let server: MCPHTTPServer

        init(endpoint: URL, server: MCPHTTPServer) {
            self.endpoint = endpoint
            self.server = server
        }

        public func shutdown() async {
            await server.shutdown()
        }
    }

    /// - Parameters:
    ///   - port: Pass 0 to bind an ephemeral loopback port.
    ///   - bearerToken: When set, requests must present this bearer token;
    ///     otherwise loopback-only allow-all applies.
    ///   - policyConfiguration: Write-exposure policy; defaults to read-only.
    public static func start(
        configuration: ASKConfiguration,
        port: UInt16 = 0,
        endpointPath: String = "/mcp",
        bearerToken: String? = nil,
        policyConfiguration: ASKMCPPolicyConfiguration? = nil
    ) throws -> RunningServer {
        let resolvedPolicy = policyConfiguration ?? ASKMCPPolicyConfiguration(policy: .readOnly)
        let mcpServer = try ASKMCPServerFactory.makeServer(
            configuration: configuration,
            policyConfiguration: resolvedPolicy
        )
        let httpConfiguration = try MCPHTTPConfiguration(
            port: port,
            endpointPath: endpointPath,
            authorizationVerifier: bearerToken.map { token in
                try MCPHTTPStaticBearerVerifier(token: token, context: MCPAuthorizationContext())
            } ?? MCPHTTPAllowAllAuthorizationVerifier()
        )
        let httpServer = MCPHTTPServer(server: mcpServer, configuration: httpConfiguration)
        let endpoint = try httpServer.start()
        return RunningServer(endpoint: endpoint, server: httpServer)
    }
}
