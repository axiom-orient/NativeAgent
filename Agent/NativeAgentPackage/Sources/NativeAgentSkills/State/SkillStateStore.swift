import Foundation

public struct SkillState: Codable, Hashable, Sendable {
    public static let currentVersion = "native-agent.skill-state/1"

    public let version: String
    public let updatedAt: Date
    public let selectionOverrides: [String: Bool]
    public let remoteSkills: [ManagedSkill]
    public let installedPlugins: [SkillPluginInstallation]

    public init(
        version: String = SkillState.currentVersion,
        updatedAt: Date = Date(),
        selectionOverrides: [String: Bool] = [:],
        remoteSkills: [ManagedSkill] = [],
        installedPlugins: [SkillPluginInstallation] = []
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.selectionOverrides = selectionOverrides
        self.remoteSkills = remoteSkills
        self.installedPlugins = installedPlugins
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case selectionOverrides
        case remoteSkills
        case installedPlugins
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported skill state version: \(version)."
            )
        }
        self.version = version
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.selectionOverrides = try container.decode([String: Bool].self, forKey: .selectionOverrides)
        self.remoteSkills = try container.decode([ManagedSkill].self, forKey: .remoteSkills)
        self.installedPlugins = try container.decode([SkillPluginInstallation].self, forKey: .installedPlugins)
    }

    package var hasCurrentContractVersions: Bool {
        version == Self.currentVersion
            && remoteSkills.allSatisfy { $0.version == ManagedSkill.currentVersion }
            && installedPlugins.allSatisfy { $0.version == SkillPluginInstallation.currentVersion }
    }

    package func applying(_ event: SkillStateEvent) -> SkillState {
        switch event {
        case let .contentsChanged(selectionOverrides, remoteSkills, installedPlugins, updatedAt):
            return SkillState(
                version: version,
                updatedAt: updatedAt,
                selectionOverrides: selectionOverrides,
                remoteSkills: remoteSkills,
                installedPlugins: installedPlugins
            )
        }
    }
}

package enum SkillStateEvent: Sendable {
    case contentsChanged(
        selectionOverrides: [String: Bool],
        remoteSkills: [ManagedSkill],
        installedPlugins: [SkillPluginInstallation],
        updatedAt: Date
    )
}

public actor SkillStateStore {
    private let persistence: SkillStatePersistence
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.persistence = SkillStatePersistence(fileURL: fileURL)
        self.fileManager = fileManager
    }

    public func prepare() throws {
        try persistence.prepare(fileManager: fileManager)
    }

    public func load() throws -> SkillState {
        try persistence.load(fileManager: fileManager)
    }

    public func save(_ state: SkillState) throws {
        try persistence.save(state, fileManager: fileManager)
    }
}
