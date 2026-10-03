import NativeAgentDomain
import NativeAgentExecution

/// Contract-only view of one Agent's configured tools.
///
/// It intentionally owns no model runtime and performs no provider I/O. Runtime capability
/// validation remains on execution paths where a concrete provider has been selected.
package struct AgentToolCatalog: Sendable {
  private let registry: ToolRegistry

  package init(
    capabilities: [any AgentCapability],
    toolPacks: [any ToolPack],
    tools: [any ToolExecutor],
    configuration: AgentConfiguration
  ) throws {
    let registry = try ToolRegistry(
      toolPacks: Agent.assembledToolPacks(
        capabilities: capabilities,
        toolPacks: toolPacks,
        tools: tools
      )
    )
    try registry.validate(resourceLimits: configuration.runtimeResourceLimits)
    self.registry = registry
  }

  package var definitions: [ToolDefinition] { registry.definitions }

  package func discover(intent: String, limit: Int) throws -> [ToolCapabilitySummary] {
    try registry.discover(intent: intent, limit: limit)
  }

  package func contract(named name: String) -> ToolDefinition? {
    registry.contract(named: name)
  }
}
