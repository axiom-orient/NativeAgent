import ASK
import ASKMCP
import Foundation
import MCPStdioServer

let environment = ProcessInfo.processInfo.environment

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("[askmcp] \(reason)\n".utf8))
    FileHandle.standardError.write(Data("""
    Usage: ASK_WORKSPACE_URL=<file:///absolute/path> askmcp

    Serves the 24 canonical ASK tools (13 effecting commands, 11 read-only \
    queries) as a stateless stdio MCP server. Configure Claude Code or any \
    MCP client to launch this binary with ASK_WORKSPACE_URL pointing at an \
    absolute local workspace path. Optional environment: ASK_POLICY=read-only, \
    staging, or full (default: read-only); full also requires non-empty \
    ASK_OPERATOR.

    """.utf8))
    exit(2)
}

guard let rawURL = environment["ASK_WORKSPACE_URL"] else {
    fail("ASK_WORKSPACE_URL is required")
}
guard let workspaceURL = URL(string: rawURL), workspaceURL.isFileURL, workspaceURL.path.hasPrefix("/") else {
    fail("ASK_WORKSPACE_URL must be an absolute file:// URL")
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
    let server = try ASKMCPServerFactory.makeServer(
        configuration: ASKConfiguration(workspaceURL: workspaceURL),
        policyConfiguration: policyConfiguration
    )
    try await MCPStdioServerRunner(server: server).run()
} catch {
    fail(String(describing: error))
}
