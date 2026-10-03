import Foundation
import MCP
import MCPStdioServer
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let tool = try MCPTool(name: "writeProof", description: "Writes a proof file and reads it back.", inputSchema: [
 "type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])]),
 "required": .array([.string("text")]), "additionalProperties": .bool(false)])
var builder = try MCPServerBuilder(implementation: try MCPImplementation(name: "file-peer", version: "1"))
builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
try builder.register(MCPStandardMethods.callTool) { params, _ in
 let value = params.arguments["text"]!.stringValue!
 let file = root.appendingPathComponent("proof.txt")
 try Data(value.utf8).write(to: file, options: .atomic)
 return try MCPCallToolResult(content: [.text(MCPTextContent(text: String(contentsOf: file, encoding: .utf8)))])
}
try await MCPStdioServerRunner(server: builder.build()).run()
