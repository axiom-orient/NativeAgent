import Foundation

extension SkillLibrary {
    package func captureExecutionSnapshot() async throws -> SkillExecutionSnapshot {
        try await prepare()
        return try await withLibraryAccess(kind: .read) {
            let state = try await stateStore.load()
            let selected = try snapshotSkills(from: state)
                .filter(\.selected)
                .sorted { $0.name < $1.name }
            var sourceRoots: [String: URL] = [:]
            sourceRoots.reserveCapacity(selected.count)
            for skill in selected {
                sourceRoots[skill.name] = try skillDirectoryURL(for: skill)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            }
            let cacheRoot = workspace.supportRootURL
                .appendingPathComponent("runtime/skill-execution-snapshots", isDirectory: true)
                .standardizedFileURL
            return try SkillExecutionSnapshot.captureSelectedSkills(
                selected,
                sourceRoots: sourceRoots,
                cacheRoot: cacheRoot,
                fileManager: fileManager
            )
        }
    }
}
