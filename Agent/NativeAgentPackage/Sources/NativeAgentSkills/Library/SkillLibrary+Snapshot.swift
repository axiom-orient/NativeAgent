import Foundation
import NativeAgentDomain

extension SkillLibrary {
    public func snapshot() async throws -> SkillLibrarySnapshot {
        try await prepare()
        return try await withLibraryAccess(kind: .read) {
            let state = try await stateStore.load()
            return try await snapshot(from: state)
        }
    }

    public func skills() async throws -> [ManagedSkill] {
        try await snapshot().skills
    }


    public func skill(named skillName: String) async throws -> ManagedSkill? {
        try await snapshot().skills.first { $0.name == skillName }
    }

    public func selectedSkills() async throws -> [ManagedSkill] {
        try await snapshot().skills.filter(\.selected)
    }

    private func snapshot(from state: SkillState) async throws -> SkillLibrarySnapshot {
        let skills = try snapshotSkills(from: state)
        let configuredSecrets = try await lookupConfiguredSecretNames(
            for: skills,
            using: secretStore
        )
        return SkillLibrarySnapshot(
            skills: skills,
            configuredSecrets: configuredSecrets,
            installedPlugins: state.installedPlugins
        )
    }

    func snapshotSkills(from state: SkillState) throws -> [ManagedSkill] {
        let bundledSkills = try loadBundledSkills(selectionOverrides: state.selectionOverrides)
        let userDocumentSkills = try loadUserDocumentSkills(
            selectionOverrides: state.selectionOverrides,
            installedPlugins: state.installedPlugins,
            webSkills: state.remoteSkills.filter { $0.source.kind == .web }
        )
        let remoteSkills = remoteStateSkills(from: state)
        let customSkills = snapshotBuilder.sortCustomSkills(
            userDocumentSkills + remoteSkills
        )
        return snapshotBuilder.mergeSkills(
            bundledSkills: bundledSkills,
            customSkills: customSkills
        )
    }
}

private func lookupConfiguredSecretNames(
    for skills: [ManagedSkill],
    using secretStore: any SkillSecretStore
) async throws -> Set<String> {
    let secretBackedSkills = skills.filter(\.requiresSecret)
    guard secretBackedSkills.isEmpty == false else {
        return []
    }

    // Running outside the library actor allows stores that support concurrent
    // reads to overlap work without creating one task per installed skill.
    let configured = try await nativeAgentBoundedConcurrentMap(
        secretBackedSkills,
        maximumConcurrentTasks: 8
    ) { skill in
        try await secretStore.hasSecret(for: skill.name) ? skill.name : nil
    }
    return Set(configured.compactMap { $0 })
}
