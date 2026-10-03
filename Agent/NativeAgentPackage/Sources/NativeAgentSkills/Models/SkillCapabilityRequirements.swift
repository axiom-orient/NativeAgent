import Foundation
import NativeAgentDomain

public struct SkillCapabilityRequirements: Codable, Hashable, Sendable {
    public let requiresNetwork: Bool
    public let allowedDomains: Set<String>
    public let requiresPersistentStorage: Bool
    public let requiresCameraOrMicrophone: Bool
    public let requiresExternalNavigation: Bool
    public let bridgeIntents: Set<String>
    public let hostIntents: Set<String>

    public init(
        requiresNetwork: Bool = false,
        allowedDomains: Set<String> = [],
        requiresPersistentStorage: Bool = false,
        requiresCameraOrMicrophone: Bool = false,
        requiresExternalNavigation: Bool = false,
        bridgeIntents: Set<String> = [],
        hostIntents: Set<String> = []
    ) {
        self.requiresNetwork = requiresNetwork
        self.allowedDomains = Set(allowedDomains.map(Self.normalizedDomain).filter { !$0.isEmpty })
        self.requiresPersistentStorage = requiresPersistentStorage
        self.requiresCameraOrMicrophone = requiresCameraOrMicrophone
        self.requiresExternalNavigation = requiresExternalNavigation
        self.bridgeIntents = Set(bridgeIntents.map(Self.normalizedIntentName).filter { !$0.isEmpty })
        self.hostIntents = Set(hostIntents.map(Self.normalizedIntentName).filter { !$0.isEmpty })
    }

    private enum CodingKeys: String, CodingKey {
        case requiresNetwork
        case allowedDomains
        case requiresPersistentStorage
        case requiresCameraOrMicrophone
        case requiresExternalNavigation
        case bridgeIntents
        case hostIntents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            requiresNetwork: try container.decode(Bool.self, forKey: .requiresNetwork),
            allowedDomains: try container.decode(Set<String>.self, forKey: .allowedDomains),
            requiresPersistentStorage: try container.decode(Bool.self, forKey: .requiresPersistentStorage),
            requiresCameraOrMicrophone: try container.decode(Bool.self, forKey: .requiresCameraOrMicrophone),
            requiresExternalNavigation: try container.decode(Bool.self, forKey: .requiresExternalNavigation),
            bridgeIntents: try container.decode(Set<String>.self, forKey: .bridgeIntents),
            hostIntents: try container.decode(Set<String>.self, forKey: .hostIntents)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requiresNetwork, forKey: .requiresNetwork)
        try container.encode(sortedAllowedDomains, forKey: .allowedDomains)
        try container.encode(requiresPersistentStorage, forKey: .requiresPersistentStorage)
        try container.encode(requiresCameraOrMicrophone, forKey: .requiresCameraOrMicrophone)
        try container.encode(requiresExternalNavigation, forKey: .requiresExternalNavigation)
        try container.encode(sortedBridgeIntents, forKey: .bridgeIntents)
        try container.encode(sortedHostIntents, forKey: .hostIntents)
    }

    public static let none = SkillCapabilityRequirements()

    public var requiresExplicitHostPolicy: Bool {
        requiresNetwork
            || requiresPersistentStorage
            || requiresCameraOrMicrophone
            || requiresExternalNavigation
            || bridgeIntents.isEmpty == false
            || hostIntents.isEmpty == false
    }

    public var sortedAllowedDomains: [String] {
        allowedDomains.sorted()
    }

    public var sortedBridgeIntents: [String] {
        bridgeIntents.sorted()
    }

    public var sortedHostIntents: [String] {
        hostIntents.sorted()
    }

    public var summary: String {
        var parts: [String] = []
        if requiresNetwork {
            let domains = sortedAllowedDomains
            parts.append(domains.isEmpty ? "network" : "network(\(domains.joined(separator: ",")))")
        }
        if requiresPersistentStorage {
            parts.append("persistent-storage")
        }
        if requiresCameraOrMicrophone {
            parts.append("camera-or-microphone")
        }
        if requiresExternalNavigation {
            parts.append("external-navigation")
        }
        if bridgeIntents.isEmpty == false {
            parts.append("bridge-intents(\(sortedBridgeIntents.joined(separator: ",")))")
        }
        if hostIntents.isEmpty == false {
            parts.append("host-intents(\(sortedHostIntents.joined(separator: ",")))")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    public var jsonValue: JSONValue {
        .object([
            "requiresNetwork": .bool(requiresNetwork),
            "allowedDomains": .array(sortedAllowedDomains.map(JSONValue.string)),
            "requiresPersistentStorage": .bool(requiresPersistentStorage),
            "requiresCameraOrMicrophone": .bool(requiresCameraOrMicrophone),
            "requiresExternalNavigation": .bool(requiresExternalNavigation),
            "bridgeIntents": .array(sortedBridgeIntents.map(JSONValue.string)),
            "hostIntents": .array(sortedHostIntents.map(JSONValue.string)),
            "requiresExplicitHostPolicy": .bool(requiresExplicitHostPolicy)
        ])
    }

    private static func normalizedDomain(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizedIntentName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
