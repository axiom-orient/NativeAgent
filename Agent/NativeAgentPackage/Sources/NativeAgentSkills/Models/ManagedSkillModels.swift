import Foundation
import NativeAgentDomain

public struct ManagedSkillSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bundled
        case imported
        case plugin
        case remote
        case web
    }

    public let kind: Kind
    public let location: String

    public init(kind: Kind, location: String) {
        self.kind = kind
        self.location = location
    }
}

public struct ManagedSkill: Codable, Hashable, Sendable, Identifiable {
    public static let currentVersion = "native-agent.skill.managed/1"

    public let version: String
    public let name: String
    public let description: String
    public let instructions: String
    public let builtIn: Bool
    public let selected: Bool
    public let requiresSecret: Bool
    public let requiresSecretDescription: String
    public let homepage: String
    public let capabilityRequirements: SkillCapabilityRequirements
    public let defaultSelected: Bool?
    public let group: String
    public let relativePath: String
    public let excerpt: String
    public let source: ManagedSkillSource
    public let executionSupport: SkillExecutionSupport
    public let executionSupportReason: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        version: String = ManagedSkill.currentVersion,
        name: String,
        description: String,
        instructions: String,
        builtIn: Bool,
        selected: Bool,
        requiresSecret: Bool,
        requiresSecretDescription: String,
        homepage: String,
        capabilityRequirements: SkillCapabilityRequirements = .none,
        defaultSelected: Bool? = nil,
        group: String,
        relativePath: String,
        excerpt: String,
        source: ManagedSkillSource,
        executionSupport: SkillExecutionSupport = .available,
        executionSupportReason: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.name = name
        self.description = description
        self.instructions = instructions
        self.builtIn = builtIn
        self.selected = selected
        self.requiresSecret = requiresSecret
        self.requiresSecretDescription = requiresSecretDescription
        self.homepage = homepage
        self.capabilityRequirements = capabilityRequirements
        self.defaultSelected = defaultSelected
        self.group = group
        self.relativePath = relativePath
        self.excerpt = excerpt
        self.source = source
        self.executionSupport = executionSupport
        self.executionSupportReason = executionSupportReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case description
        case instructions
        case builtIn
        case selected
        case requiresSecret
        case requiresSecretDescription
        case homepage
        case capabilityRequirements
        case defaultSelected
        case group
        case relativePath
        case excerpt
        case source
        case executionSupport
        case executionSupportReason
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported managed skill version: \(version)."
            )
        }
        self.version = version
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.instructions = try container.decode(String.self, forKey: .instructions)
        self.builtIn = try container.decode(Bool.self, forKey: .builtIn)
        self.selected = try container.decode(Bool.self, forKey: .selected)
        self.requiresSecret = try container.decode(Bool.self, forKey: .requiresSecret)
        self.requiresSecretDescription = try container.decode(String.self, forKey: .requiresSecretDescription)
        self.homepage = try container.decode(String.self, forKey: .homepage)
        self.capabilityRequirements = try container.decode(SkillCapabilityRequirements.self, forKey: .capabilityRequirements)
        self.defaultSelected = try container.decodeIfPresent(Bool.self, forKey: .defaultSelected)
        self.group = try container.decode(String.self, forKey: .group)
        self.relativePath = try container.decode(String.self, forKey: .relativePath)
        self.excerpt = try container.decode(String.self, forKey: .excerpt)
        self.source = try container.decode(ManagedSkillSource.self, forKey: .source)
        self.executionSupport = try container.decode(SkillExecutionSupport.self, forKey: .executionSupport)
        self.executionSupportReason = try container.decode(String.self, forKey: .executionSupportReason)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public var id: String { name }

    public var title: String {
        name
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    public var sourceLabel: String {
        switch source.kind {
        case .bundled:
            return builtIn ? "Built-in" : "Featured"
        case .imported:
            return "Imported"
        case .plugin:
            return "Plugin"
        case .remote:
            return "Remote"
        case .web:
            return "Web"
        }
    }

    public var isExecutionAvailable: Bool {
        executionSupport == .available
    }

    public var requiresExplicitHostPolicy: Bool {
        capabilityRequirements.requiresExplicitHostPolicy || requiresSecret
    }

    public var hostPolicySummary: String {
        var parts: [String] = []
        if requiresSecret { parts.append("secret") }
        if capabilityRequirements.requiresExplicitHostPolicy { parts.append(capabilityRequirements.summary) }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    public var hasExecutableInstructions: Bool {
        instructions.localizedCaseInsensitiveContains("run_js") || instructions.localizedCaseInsensitiveContains("run_intent")
    }

    public func instructionsPreview(limit: Int = 320) -> String {
        let normalized = instructions
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    package func applying(_ event: ManagedSkillEvent) -> ManagedSkill {
        switch event {
        case let .selectionChanged(selected, updatedAt):
            return replacing(selected: selected, updatedAt: updatedAt)
        case let .executionSupportChanged(support, reason, updatedAt):
            return replacing(execution: (support, reason), updatedAt: updatedAt)
        case let .groupChanged(group):
            return replacing(group: group)
        case .excerptRefreshed:
            return replacing(excerpt: instructionsPreview())
        }
    }

    private func replacing(
        selected: Bool? = nil,
        group: String? = nil,
        excerpt: String? = nil,
        execution: (SkillExecutionSupport, String)? = nil,
        updatedAt: Date? = nil
    ) -> ManagedSkill {
        ManagedSkill(
            version: version,
            name: name,
            description: description,
            instructions: instructions,
            builtIn: builtIn,
            selected: selected ?? self.selected,
            requiresSecret: requiresSecret,
            requiresSecretDescription: requiresSecretDescription,
            homepage: homepage,
            capabilityRequirements: capabilityRequirements,
            defaultSelected: defaultSelected,
            group: group ?? self.group,
            relativePath: relativePath,
            excerpt: excerpt ?? self.excerpt,
            source: source,
            executionSupport: execution?.0 ?? executionSupport,
            executionSupportReason: execution?.1 ?? executionSupportReason,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }
}

package enum ManagedSkillEvent: Sendable {
    case selectionChanged(Bool, updatedAt: Date? = nil)
    case executionSupportChanged(SkillExecutionSupport, reason: String, updatedAt: Date? = nil)
    case groupChanged(String)
    case excerptRefreshed
}

public enum SkillExecutionSupport: String, Codable, Hashable, Sendable {
    case available
    case unavailableOnMobile
}

public struct SkillLibrarySnapshot: Sendable, Hashable {
    public let skills: [ManagedSkill]
    public let configuredSecrets: Set<String>
    public let installedPlugins: [SkillPluginInstallation]

    public init(
        skills: [ManagedSkill],
        configuredSecrets: Set<String>,
        installedPlugins: [SkillPluginInstallation] = []
    ) {
        self.skills = skills
        self.configuredSecrets = configuredSecrets
        self.installedPlugins = installedPlugins
    }
}

public struct SkillPluginManifest: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = "native-agent.skill.plugin/1"

    public let schemaVersion: String
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let homepage: String
    public let skills: [SkillPluginSkill]

    public init(
        schemaVersion: String = SkillPluginManifest.supportedSchemaVersion,
        id: String,
        name: String,
        version: String,
        description: String,
        homepage: String = "",
        skills: [SkillPluginSkill] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.homepage = homepage
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case version
        case description
        case homepage
        case skills
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported skill plugin schema: \(schemaVersion)."
            )
        }
        self.schemaVersion = schemaVersion
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.description = try container.decode(String.self, forKey: .description)
        self.homepage = try container.decode(String.self, forKey: .homepage)
        self.skills = try container.decode([SkillPluginSkill].self, forKey: .skills)
    }
}

public struct SkillPluginSkill: Codable, Hashable, Sendable {
    public let path: String
    public let selected: Bool?

    public init(path: String, selected: Bool? = nil) {
        self.path = path
        self.selected = selected
    }
}

public struct SkillPluginInstallation: Codable, Hashable, Sendable, Identifiable {
    public static let currentVersion = "native-agent.skill.plugin-installation/1"

    public let version: String
    public let id: String
    public let name: String
    public let pluginVersion: String
    public let description: String
    public let homepage: String
    public let sourceLocation: String
    public let installedSkills: [SkillPluginInstalledSkill]
    public let installedAt: Date
    public let updatedAt: Date

    public init(
        version: String = SkillPluginInstallation.currentVersion,
        id: String,
        name: String,
        pluginVersion: String,
        description: String,
        homepage: String,
        sourceLocation: String,
        installedSkills: [SkillPluginInstalledSkill],
        installedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.pluginVersion = pluginVersion
        self.description = description
        self.homepage = homepage
        self.sourceLocation = sourceLocation
        self.installedSkills = installedSkills
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case name
        case pluginVersion
        case description
        case homepage
        case sourceLocation
        case installedSkills
        case installedAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported skill plugin installation version: \(version)."
            )
        }
        self.version = version
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.pluginVersion = try container.decode(String.self, forKey: .pluginVersion)
        self.description = try container.decode(String.self, forKey: .description)
        self.homepage = try container.decode(String.self, forKey: .homepage)
        self.sourceLocation = try container.decode(String.self, forKey: .sourceLocation)
        self.installedSkills = try container.decode([SkillPluginInstalledSkill].self, forKey: .installedSkills)
        self.installedAt = try container.decode(Date.self, forKey: .installedAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct SkillPluginInstalledSkill: Codable, Hashable, Sendable {
    public let name: String
    public let directoryName: String
    public let manifestPath: String
    public let selected: Bool

    public init(
        name: String,
        directoryName: String,
        manifestPath: String,
        selected: Bool
    ) {
        self.name = name
        self.directoryName = directoryName
        self.manifestPath = manifestPath
        self.selected = selected
    }
}
