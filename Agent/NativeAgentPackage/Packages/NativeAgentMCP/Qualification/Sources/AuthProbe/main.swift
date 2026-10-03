import Foundation
import MCP
import MCPHTTPClient
import NativeAgentMCP
let endpoint = URL(string: CommandLine.arguments[1])!
let config = try MCPClientConfiguration(implementation: MCPImplementation(name: "auth-probe", version: "1"), capabilities: MCPClientCapabilities())
for token in [nil, "wrong"] as [String?] {
 let auth = try token.map { try MCPStaticBearerTokenProvider(token: $0) }
 let transport = MCPHTTPClientTransport(configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, authorizationProvider: auth, networkTimeout: 10))
 do {
  _ = try await MCPToolPack.discover(serverID: "auth", transport: transport, configuration: config)
  throw NSError(domain: "unauthorized-was-accepted", code: 1)
 } catch MCPClientError.transportFailure(let failure) {
  guard let error = failure as? MCPHTTPUnauthorizedResponse else { throw failure }
  guard error.wwwAuthenticate == "Bearer realm=\"qualification\"" else { throw NSError(domain: "challenge-lost", code: 1) }
 }
}
let transport = MCPHTTPClientTransport(configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, authorizationProvider: MCPStaticBearerTokenProvider(token: "qualification-only"), networkTimeout: 10))
let pack = try await MCPToolPack.discover(serverID: "auth", transport: transport, configuration: config)
guard pack.executors().count == 1 else { throw NSError(domain: "discovery", code: 1) }
print("MCP_AUTH none=401 wrong=401 valid=discovered challenge=preserved")
