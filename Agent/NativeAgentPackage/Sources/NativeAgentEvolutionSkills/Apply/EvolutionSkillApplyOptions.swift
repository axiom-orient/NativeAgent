import Foundation
import NativeAgentEvolution

public struct EvolutionSkillApplyOptions: Codable, Sendable, Equatable {
    public let skillName: String?
    public let description: String?
    public let selected: Bool
    public let requiresSecret: Bool?
    public let requiresSecretDescription: String?
    public let homepage: String?
    public let scripts: [String: String]
    public let assets: [String: String]
    public let binaryAssets: [String: Data]

    public init(
        skillName: String? = nil,
        description: String? = nil,
        selected: Bool = true,
        requiresSecret: Bool? = nil,
        requiresSecretDescription: String? = nil,
        homepage: String? = nil,
        scripts: [String: String] = [:],
        assets: [String: String] = [:],
        binaryAssets: [String: Data] = [:]
    ) {
        self.skillName = skillName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyForNativeAgentEvolution
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyForNativeAgentEvolution
        self.selected = selected
        self.requiresSecret = requiresSecret
        self.requiresSecretDescription = requiresSecretDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.homepage = homepage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scripts = scripts
        self.assets = assets
        self.binaryAssets = binaryAssets
    }

    private enum CodingKeys: String, CodingKey {
        case skillName = "skill_name"
        case description
        case selected
        case requiresSecret = "requires_secret"
        case requiresSecretDescription = "requires_secret_description"
        case homepage
        case scripts
        case assets
        case binaryAssets = "binary_assets"
    }
}
