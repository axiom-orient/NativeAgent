import Foundation
import NativeAgentDomain

public struct SkillMarkdownDocument: Sendable, Hashable {
    public let name: String
    public let description: String
    public let instructions: String
    public let requiresSecret: Bool
    public let requiresSecretDescription: String
    public let homepage: String
    public let capabilityRequirements: SkillCapabilityRequirements
    public let defaultSelected: Bool?

    public init(
        name: String,
        description: String,
        instructions: String,
        requiresSecret: Bool,
        requiresSecretDescription: String,
        homepage: String,
        capabilityRequirements: SkillCapabilityRequirements = .none,
        defaultSelected: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.requiresSecret = requiresSecret
        self.requiresSecretDescription = requiresSecretDescription
        self.homepage = homepage
        self.capabilityRequirements = capabilityRequirements
        self.defaultSelected = defaultSelected
    }
}

struct SkillMarkdownFrontmatter: Sendable, Hashable {
    var name: String
    var description: String
    var requiresSecret: Bool
    var requiresSecretDescription: String
    var homepage: String
    var capabilityRequirements: SkillCapabilityRequirements
    var defaultSelected: Bool?

    var bundledDefaultSelected: Bool {
        if let defaultSelected { return defaultSelected }
        return requiresSecret == false && capabilityRequirements.requiresExplicitHostPolicy == false
    }
}

private struct SkillMarkdownLine {
    let raw: String
    let indent: Int
    let trimmed: String

    init(_ raw: String) {
        self.raw = raw
        self.indent = raw.prefix { $0 == " " || $0 == "\t" }.count
        self.trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SkillMarkdownFrontmatterParser {
    static func parse(_ markdown: String) throws -> (frontmatter: SkillMarkdownFrontmatter, instructions: String) {
        let split = try splitFrontmatter(markdown)
        let headerLines = split.header.components(separatedBy: .newlines).map(SkillMarkdownLine.init)

        var name: String?
        var description: String?
        var requiresSecret = false
        var requiresSecretDescription = ""
        var homepage = ""
        var requiresNetwork = false
        var allowedDomains = Set<String>()
        var requiresPersistentStorage = false
        var requiresCameraOrMicrophone = false
        var requiresExternalNavigation = false
        var bridgeIntents = Set<String>()
        var hostIntents = Set<String>()
        var defaultSelected: Bool?

        var inMetadata = false
        var activeListKey: String?

        for line in headerLines {
            guard line.trimmed.isEmpty == false, line.trimmed.hasPrefix("#") == false else { continue }

            if line.indent == 0 {
                activeListKey = nil
                if line.trimmed == "metadata:" {
                    inMetadata = true
                    continue
                }
                inMetadata = false
                try applyKeyValue(
                    line.trimmed,
                    name: &name,
                    description: &description,
                    requiresSecret: &requiresSecret,
                    requiresSecretDescription: &requiresSecretDescription,
                    homepage: &homepage,
                    requiresNetwork: &requiresNetwork,
                    allowedDomains: &allowedDomains,
                    requiresPersistentStorage: &requiresPersistentStorage,
                    requiresCameraOrMicrophone: &requiresCameraOrMicrophone,
                    requiresExternalNavigation: &requiresExternalNavigation,
                    bridgeIntents: &bridgeIntents,
                    hostIntents: &hostIntents,
                    defaultSelected: &defaultSelected,
                    activeListKey: &activeListKey
                )
                continue
            }

            guard inMetadata else { continue }
            let metadataLine = line.raw.dropFirst(line.indent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard metadataLine.isEmpty == false else { continue }

            if metadataLine.hasPrefix("-"), let key = activeListKey {
                let item = scalarValue(
                    metadataLine.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try applyListItem(
                    key: key,
                    item: item,
                    allowedDomains: &allowedDomains,
                    bridgeIntents: &bridgeIntents,
                    hostIntents: &hostIntents
                )
                continue
            }

            try applyKeyValue(
                metadataLine,
                name: &name,
                description: &description,
                requiresSecret: &requiresSecret,
                requiresSecretDescription: &requiresSecretDescription,
                homepage: &homepage,
                requiresNetwork: &requiresNetwork,
                allowedDomains: &allowedDomains,
                requiresPersistentStorage: &requiresPersistentStorage,
                requiresCameraOrMicrophone: &requiresCameraOrMicrophone,
                requiresExternalNavigation: &requiresExternalNavigation,
                bridgeIntents: &bridgeIntents,
                hostIntents: &hostIntents,
                defaultSelected: &defaultSelected,
                activeListKey: &activeListKey
            )
        }

        guard let name, !name.isEmpty else {
            throw AgentError.invalidToolCall("Missing skill name in SKILL.md")
        }
        guard let description, !description.isEmpty else {
            throw AgentError.invalidToolCall("Missing skill description in SKILL.md")
        }
        try validateAgentSkillsIdentity(name: name, description: description)

        return (
            SkillMarkdownFrontmatter(
                name: name,
                description: description,
                requiresSecret: requiresSecret,
                requiresSecretDescription: requiresSecretDescription,
                homepage: homepage,
                capabilityRequirements: SkillCapabilityRequirements(
                    requiresNetwork: requiresNetwork,
                    allowedDomains: allowedDomains,
                    requiresPersistentStorage: requiresPersistentStorage,
                    requiresCameraOrMicrophone: requiresCameraOrMicrophone,
                    requiresExternalNavigation: requiresExternalNavigation,
                    bridgeIntents: bridgeIntents,
                    hostIntents: hostIntents
                ),
                defaultSelected: defaultSelected
            ),
            split.instructions
        )
    }

    private static func splitFrontmatter(_ markdown: String) throws -> (header: String, instructions: String) {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let firstNonEmpty = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }), lines[firstNonEmpty].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            throw AgentError.invalidToolCall("Invalid SKILL.md format: expected frontmatter delimited by ---")
        }

        guard let closing = lines[(firstNonEmpty + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            throw AgentError.invalidToolCall("Invalid SKILL.md format: missing closing --- for frontmatter")
        }

        let header = lines[(firstNonEmpty + 1)..<closing].joined(separator: "\n")
        let instructions = lines[(closing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (header, instructions)
    }

    private static func applyKeyValue(
        _ line: String,
        name: inout String?,
        description: inout String?,
        requiresSecret: inout Bool,
        requiresSecretDescription: inout String,
        homepage: inout String,
        requiresNetwork: inout Bool,
        allowedDomains: inout Set<String>,
        requiresPersistentStorage: inout Bool,
        requiresCameraOrMicrophone: inout Bool,
        requiresExternalNavigation: inout Bool,
        bridgeIntents: inout Set<String>,
        hostIntents: inout Set<String>,
        defaultSelected: inout Bool?,
        activeListKey: inout String?
    ) throws {
        guard let colon = line.firstIndex(of: ":") else { return }
        let rawKey = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)

        if rawValue.isEmpty {
            activeListKey = rawKey
            switch rawKey {
            case "allowed-domains": allowedDomains.removeAll()
            case "bridge-intents": bridgeIntents.removeAll()
            case "host-intents": hostIntents.removeAll()
            default: break
            }
            return
        }

        activeListKey = nil

        switch rawKey {
        case "name":
            name = scalarValue(rawValue)
        case "description":
            description = scalarValue(rawValue)
        case "require-secret", "requires-secret":
            requiresSecret = boolValue(rawValue) ?? false
        case "require-secret-description", "requires-secret-description":
            requiresSecretDescription = scalarValue(rawValue)
        case "homepage":
            homepage = scalarValue(rawValue)
        case "requires-network":
            requiresNetwork = boolValue(rawValue) ?? false
        case "allowed-domains":
            allowedDomains = Set(listValue(rawValue).map { $0.lowercased() })
        case "requires-persistent-storage":
            requiresPersistentStorage = boolValue(rawValue) ?? false
        case "requires-camera-or-microphone":
            requiresCameraOrMicrophone = boolValue(rawValue) ?? false
        case "requires-external-navigation":
            requiresExternalNavigation = boolValue(rawValue) ?? false
        case "bridge-intents":
            bridgeIntents = Set(listValue(rawValue))
        case "host-intents":
            hostIntents = Set(listValue(rawValue))
        case "default-selected":
            defaultSelected = boolValue(rawValue)
        default:
            return
        }
    }

    private static func applyListItem(
        key: String,
        item: String,
        allowedDomains: inout Set<String>,
        bridgeIntents: inout Set<String>,
        hostIntents: inout Set<String>
    ) throws {
        guard item.isEmpty == false else { return }
        switch key {
        case "allowed-domains":
            allowedDomains.insert(item.lowercased())
        case "bridge-intents":
            bridgeIntents.insert(item)
        case "host-intents":
            hostIntents.insert(item)
        default:
            return
        }
    }

    private static func scalarValue<S: StringProtocol>(_ raw: S) -> String {
        let value = String(raw)
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func validateAgentSkillsIdentity(name: String, description: String) throws {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count),
              !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--"),
              bytes.allSatisfy({ byte in
                  switch byte {
                  case 45, 48...57, 97...122: true
                  default: false
                  }
              }) else {
            throw AgentError.invalidToolCall(
                "Skill name must follow the Agent Skills 1...64 lowercase letters/numbers/hyphens contract"
            )
        }
        guard (1...1_024).contains(description.count) else {
            throw AgentError.invalidToolCall(
                "Skill description must be 1...1024 characters"
            )
        }
    }

    static func validateDirectoryIdentity(skillName: String, directoryName: String) throws {
        guard skillName == directoryName else {
            throw AgentError.invalidToolCall(
                "Skill name must exactly match its parent directory: \(directoryName)"
            )
        }
    }

    private static func boolValue(_ raw: String) -> Bool? {
        switch scalarValue(raw).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func listValue(_ raw: String) -> [String] {
        var value = scalarValue(raw)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        return value
            .split(separator: ",")
            .map { item in
                item
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            .filter { !$0.isEmpty }
    }
}

public enum SkillMarkdownParser {
    public static func parse(
        _ markdown: String,
        builtIn: Bool,
        selected: Bool,
        group: String,
        relativePath: String,
        source: ManagedSkillSource,
        now: Date = Date()
    ) throws -> ManagedSkill {
        let parsed = try SkillMarkdownFrontmatterParser.parse(markdown)
        let frontmatter = parsed.frontmatter
        let instructions = parsed.instructions

        let skill = ManagedSkill(
            name: frontmatter.name,
            description: frontmatter.description,
            instructions: instructions,
            builtIn: builtIn,
            selected: selected,
            requiresSecret: frontmatter.requiresSecret,
            requiresSecretDescription: frontmatter.requiresSecretDescription,
            homepage: frontmatter.homepage,
            capabilityRequirements: frontmatter.capabilityRequirements,
            defaultSelected: frontmatter.defaultSelected,
            group: group,
            relativePath: relativePath,
            excerpt: instructions,
            source: source,
            createdAt: now,
            updatedAt: now
        )
        return skill.applying(.excerptRefreshed)
    }

    static func bundledDefaultSelected(in markdown: String) throws -> Bool {
        try SkillMarkdownFrontmatterParser.parse(markdown).frontmatter.bundledDefaultSelected
    }

    public static func render(document: SkillMarkdownDocument) -> String {
        var lines = [
            "---",
            "name: \(document.name)",
            "description: \(document.description)"
        ]

        let requirements = document.capabilityRequirements
        let hasMetadata = document.requiresSecret
            || !document.requiresSecretDescription.isEmpty
            || !document.homepage.isEmpty
            || requirements != .none
            || document.defaultSelected != nil

        if hasMetadata {
            lines.append("metadata:")
            if document.requiresSecret {
                lines.append("  require-secret: true")
            }
            if !document.requiresSecretDescription.isEmpty {
                lines.append("  require-secret-description: \(document.requiresSecretDescription)")
            }
            if !document.homepage.isEmpty {
                lines.append("  homepage: \(document.homepage)")
            }
            if requirements.requiresNetwork {
                lines.append("  requires-network: true")
            }
            appendList("allowed-domains", values: requirements.sortedAllowedDomains, to: &lines)
            if requirements.requiresPersistentStorage {
                lines.append("  requires-persistent-storage: true")
            }
            if requirements.requiresCameraOrMicrophone {
                lines.append("  requires-camera-or-microphone: true")
            }
            if requirements.requiresExternalNavigation {
                lines.append("  requires-external-navigation: true")
            }
            appendList("bridge-intents", values: requirements.sortedBridgeIntents, to: &lines)
            appendList("host-intents", values: requirements.sortedHostIntents, to: &lines)
            if let defaultSelected = document.defaultSelected {
                lines.append("  default-selected: \(defaultSelected ? "true" : "false")")
            }
        }

        lines.append("---")
        lines.append("")
        lines.append(document.instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    private static func appendList(_ key: String, values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("  \(key):")
        lines.append(contentsOf: values.map { "    - \($0)" })
    }
}
