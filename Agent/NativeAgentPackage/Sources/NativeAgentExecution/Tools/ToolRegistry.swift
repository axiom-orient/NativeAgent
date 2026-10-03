import Foundation
import NativeAgentDomain

public struct ToolRegistry: Sendable {
    public static let minimumDiscoveryLimit = 1
    public static let standardDiscoveryLimit = 8
    public static let supportedMaximumDiscoveryLimit = 64

    private let executorMap: [String: any ToolExecutor]
    private let definitionMap: [String: ToolDefinition]
    public let definitions: [ToolDefinition]

    public init(toolPacks: [any ToolPack]) throws {
        var executors: [String: any ToolExecutor] = [:]

        for pack in toolPacks {
            for executor in pack.executors() {
                let name = executor.definition.name
                if executors[name] != nil {
                    throw AgentError.invariantViolation("Duplicate tool name registered: \(name)")
                }
                executors[name] = executor
            }
        }

        let definitions = executors.values.map(\.definition)
        self.executorMap = executors
        self.definitionMap = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        self.definitions = definitions.sorted { $0.name < $1.name }
    }

    /// Package-only recovery construction. `contractOnlyDefinitions` participate in validation and
    /// recovery inspection but intentionally have no executor in this registry.
    package init(
        toolPacks: [any ToolPack],
        contractOnlyDefinitions: [ToolDefinition]
    ) throws {
        var executors: [String: any ToolExecutor] = [:]
        var definitions: [String: ToolDefinition] = [:]

        for pack in toolPacks {
            for executor in pack.executors() {
                let definition = executor.definition
                let name = definition.name
                if definitions[name] != nil {
                    throw AgentError.invariantViolation("Duplicate tool name registered: \(name)")
                }
                executors[name] = executor
                definitions[name] = definition
            }
        }

        for definition in contractOnlyDefinitions {
            let name = definition.name
            if definitions[name] != nil {
                throw AgentError.invariantViolation("Duplicate tool name registered: \(name)")
            }
            definitions[name] = definition
        }

        self.executorMap = executors
        self.definitionMap = definitions
        self.definitions = definitions.values.sorted { $0.name < $1.name }
    }

    public func executor(named name: String) -> (any ToolExecutor)? {
        executorMap[name]
    }

    public func definition(named name: String) -> ToolDefinition? {
        definitionMap[name]
    }

    /// Validates the model-visible tool surface without constructing a model runtime.
    package func validate(resourceLimits: RuntimeResourceLimits) throws {
        try RuntimeResourceValidator(limits: resourceLimits).validate(toolDefinitions: definitions)
    }

    /// Bounded deterministic capability discovery over tools that are actually
    /// registered and executable in this registry. Discovery never grants
    /// execution authority and never fabricates catalog-only capabilities.
    public func discover(
        intent: String,
        limit: Int = ToolRegistry.standardDiscoveryLimit
    ) throws -> [ToolCapabilitySummary] {
        guard (Self.minimumDiscoveryLimit...Self.supportedMaximumDiscoveryLimit).contains(limit) else {
            throw AgentError.invalidConfiguration(
                "Tool discovery limit must be between \(Self.minimumDiscoveryLimit) and \(Self.supportedMaximumDiscoveryLimit)."
            )
        }
        let terms = Self.discoveryTerms(intent)
        let ranked = definitions.compactMap { definition -> (Int, ToolDefinition)? in
            let score = Self.discoveryScore(definition: definition, terms: terms)
            guard terms.isEmpty || score > 0 else { return nil }
            return (score, definition)
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.name < rhs.1.name
        }
        return ranked.prefix(limit).map { ToolCapabilitySummary(definition: $0.1) }
    }

    /// Loads the full contract only after a stable capability identifier has
    /// been selected by discovery or by a trusted host.
    public func contract(named name: String) -> ToolDefinition? {
        definition(named: name)
    }

    private static func discoveryTerms(_ intent: String) -> [String] {
        intent.lowercased().split { character in
            character.isLetter == false && character.isNumber == false
        }.map(String.init).filter { $0.isEmpty == false }
    }

    private static func discoveryScore(
        definition: ToolDefinition,
        terms: [String]
    ) -> Int {
        guard terms.isEmpty == false else { return 1 }
        let name = definition.name.lowercased()
        let capability = definition.capabilityID.rawValue.lowercased()
        let description = definition.description.lowercased()
        return terms.reduce(into: 0) { score, term in
            if name == term { score += 16 }
            if name.hasPrefix(term) { score += 8 }
            if name.contains(term) { score += 6 }
            if capability == term { score += 8 }
            if capability.contains(term) { score += 4 }
            if description.contains(term) { score += 2 }
        }
    }

    package func containsSensitiveData(in calls: [ToolCall]) -> Bool {
        calls.contains { call in
            definition(named: call.name)?.containsSensitiveData == true
        }
    }
}
