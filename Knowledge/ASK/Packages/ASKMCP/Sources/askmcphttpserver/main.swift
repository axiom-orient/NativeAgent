import ASK
import ASKMCP
import ASKMCPHTTP
import Foundation
import MCPHTTPServer

let environment = ProcessInfo.processInfo.environment

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("[ask-mcp-http] \(reason)\n".utf8))
    FileHandle.standardError.write(Data("""
    Usage: ASK_WORKSPACE_URL=<file:///absolute/path> ask-mcp-http

    Serves the 24 canonical ASK tools over request-scoped HTTP POST on a
    loopback endpoint. Environment:
      ASK_HTTP_PORT     port to bind (default: 0 = ephemeral)
      ASK_HTTP_TOKEN    require this bearer token on every call
      ASK_POLICY        read-only, staging, or full (default: read-only)
      ASK_OPERATOR      required and non-empty when ASK_POLICY=full

    """.utf8))
    exit(2)
}

guard let rawURL = environment["ASK_WORKSPACE_URL"] else {
    fail("ASK_WORKSPACE_URL is required")
}
guard let workspaceURL = URL(string: rawURL), workspaceURL.isFileURL, workspaceURL.path.hasPrefix("/") else {
    fail("ASK_WORKSPACE_URL must be an absolute file:// URL")
}
var port: UInt16 = 0
if let rawPort = environment["ASK_HTTP_PORT"] {
    guard let parsed = UInt16(rawPort) else { fail("ASK_HTTP_PORT must be a UInt16") }
    port = parsed
}

do {
    var policyConfiguration = ASKMCPPolicyConfiguration(policy: .readOnly)
    if let rawPolicy = environment["ASK_POLICY"] {
        policyConfiguration = ASKMCPPolicyConfiguration(
            policy: try ASKMCPPolicy(parsing: rawPolicy),
            operatorIdentity: environment["ASK_OPERATOR"]
        )
    }
    if let rawReadRoot = environment["ASK_READ_ROOT_URL"] {
        guard let readRoot = URL(string: rawReadRoot), readRoot.isFileURL, readRoot.path.hasPrefix("/") else {
            fail("ASK_READ_ROOT_URL must be an absolute file:// URL")
        }
        policyConfiguration = ASKMCPPolicyConfiguration(
            policy: policyConfiguration.policy,
            operatorIdentity: policyConfiguration.operatorIdentity,
            additionalReadRoots: [readRoot]
        )
    }
    let running = try ASKMCPHTTPServerFactory.start(
        configuration: ASKConfiguration(workspaceURL: workspaceURL),
        port: port,
        bearerToken: environment["ASK_HTTP_TOKEN"],
        policyConfiguration: policyConfiguration
    )
    FileHandle.standardError.write(Data("[ask-mcp-http] serving \(running.endpoint)\n".utf8))
    dispatchMain()
} catch {
    fail(String(describing: error))
}
