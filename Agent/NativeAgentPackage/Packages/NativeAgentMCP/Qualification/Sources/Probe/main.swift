import Foundation
import MCP
import MCPStdioClient
import NativeAgentMCP
import NativeAgentDomain
let root = URL(fileURLWithPath: CommandLine.arguments[3])
let executable = URL(fileURLWithPath: CommandLine.arguments[1])
let peerScript = CommandLine.arguments[2]
func connect() async throws -> (MCPStdioClientTransport, any ToolExecutor) {
 let transport = MCPStdioClientTransport(configuration: try MCPStdioClientConfiguration(executableURL: executable, arguments: [peerScript, root.path]))
 do {
  let client = try MCPClient(transport: MCPCancellationSafeTransport(transport), configuration: MCPClientConfiguration(implementation: try MCPImplementation(name: "lifecycle-probe", version: "1"), capabilities: MCPClientCapabilities()))
  let pack = try await MCPToolPack.discover(serverID: "live", client: client)
  return (transport, pack.executors()[0])
 } catch { await transport.shutdown(); throw error }
}
func execute(_ executor: any ToolExecutor, _ text: String) async throws -> ToolResult {
 try await executor.execute(call: ToolCall(id: UUID().uuidString, name: executor.definition.name, arguments: .object(["text": .string(text)])), context: ToolExecutionContext(sessionID: "live", sessionDirectoryURL: root, sandboxRootURL: root))
}
func awaitFile(_ name: String) async throws {
 let deadline = ContinuousClock.now.advanced(by: .seconds(10))
 while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
  guard ContinuousClock.now < deadline else { throw NSError(domain: "file-timeout", code: 1) }
  try await Task.sleep(for: .milliseconds(20))
 }
}
let (transport, executor) = try await connect()
do {
 let pending = Task { try await execute(executor, "DELAY") }
 try await awaitFile("started.txt")
 pending.cancel()
 do { _ = try await pending.value; throw NSError(domain: "cancel-not-observed", code: 1) }
 catch is CancellationError { }
 catch MCPClientError.cancelled { }
 try await awaitFile("cancelled.txt")
 let result = try await execute(executor, "AFTER_CANCEL")
 guard !result.isError, try String(contentsOf: root.appendingPathComponent("proof.txt"), encoding: .utf8) == "AFTER_CANCEL" else { throw NSError(domain: "readback", code: 1) }
 print("MCP_LIFECYCLE remoteCancellation=observed reuse=observed")
 var disconnected = false
 do { _ = try await execute(executor, "CRASH") } catch { disconnected = true }
 guard disconnected else { throw NSError(domain: "disconnect-not-observed", code: 1) }
 await transport.shutdown()
 let (fresh, next) = try await connect()
 do {
  let result = try await execute(next, "EXPLICIT_RECONNECT")
  guard !result.isError, try String(contentsOf: root.appendingPathComponent("proof.txt"), encoding: .utf8) == "EXPLICIT_RECONNECT" else { throw NSError(domain: "reconnect", code: 1) }
  await fresh.shutdown()
 } catch { await fresh.shutdown(); throw error }
 print("MCP_LIFECYCLE disconnect=error explicitReconnect=observed cleanup=closed")
} catch { await transport.shutdown(); throw error }
