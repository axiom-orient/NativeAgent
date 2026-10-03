import Foundation
import NativeAgentDomain

extension SkillLibrary {

    @discardableResult
    public func installSkillPlugins(
        fromRemoteRepositoryURL remoteRepositoryURLString: String,
        selectedByDefault: Bool = true
    ) async throws -> [SkillPluginInstallation] {
        try await prepare()
        let repositoryURL = try normalizeRemoteSkillBaseURL(remoteRepositoryURLString)
        let repository = try await remoteFetcher.fetchSkillPluginRepository(repositoryURL: repositoryURL)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-agent-remote-skill-plugins-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        var installations: [SkillPluginInstallation]?
        var operationFailure: (any Error)?
        do {
            var packageDirectories: [(package: RemoteSkillPluginPackage, directory: URL)] = []
            for (index, package) in repository.pluginPackages.enumerated() {
                let directoryName = remotePluginStagingDirectoryName(for: package, index: index)
                let pluginDirectory = temporaryRoot.appendingPathComponent(
                    directoryName,
                    isDirectory: true
                )
                try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
                try writeRemotePluginPackage(package, to: pluginDirectory)
                packageDirectories.append((package, pluginDirectory))
            }

            installations = try await withLibraryAccess(kind: .pluginMutation) {
                let state = try await stateStore.load()
                let timestamp = now()
                let requests = try packageDirectories.map { entry in
                    try preparePluginInstallRequest(
                        fromDirectoryURL: entry.directory,
                        selectedByDefault: selectedByDefault,
                        sourceLocation: entry.package.sourceLocation,
                        state: state,
                        updatedAt: timestamp
                    )
                }
                let occupiedSkillNames = Set(try snapshotSkills(from: state).map(\.name))
                let plan = try SkillPluginMutationReducer().reduce(
                    state: state,
                    action: .install(
                        requests: requests,
                        occupiedSkillNames: occupiedSkillNames
                    )
                )
                try await workspaceTransaction.perform(plan.workspaceMutation)
                return plan.installations
            }
        } catch {
            operationFailure = error
        }

        try finishRemotePluginTemporaryWorkspace(
            temporaryRoot,
            operationFailure: operationFailure,
            operationCommitted: installations != nil
        )
        guard let installations else {
            throw AgentError.invariantViolation(
                "Remote skill plugin installation completed without a result or an error")
        }
        return installations
    }

    @discardableResult
    public func uninstallSkillPlugins(fromRemoteRepositoryURL remoteRepositoryURLString: String) async throws -> [String] {
        try await prepare()
        let repositoryURL = try normalizeRemoteSkillBaseURL(remoteRepositoryURLString)
        let normalizedSource = normalizedRemoteRepositorySource(repositoryURL)
        return try await withLibraryAccess(kind: .pluginMutation) {
            let state = try await stateStore.load()
            let matchingIDs = state.installedPlugins
                .filter { installation in
                    let source = installation.sourceLocation.trimmedTrailingSlash()
                    return source == normalizedSource || source.hasPrefix("\(normalizedSource)#")
                }
                .map(\.id)
            guard !matchingIDs.isEmpty else {
                throw AgentError.notFound("No installed skill plugins match remote repository: \(normalizedSource)")
            }
            let plan = try SkillPluginMutationReducer().reduce(
                state: state,
                action: .uninstall(pluginIDs: Set(matchingIDs), updatedAt: now())
            )
            try await workspaceTransaction.perform(plan.workspaceMutation)
            return matchingIDs
        }
    }

    private func writeRemotePluginPackage(_ package: RemoteSkillPluginPackage, to destinationURL: URL) throws {
        for file in package.files {
            let relativePath = try sanitizeRelativeSkillPath(file.relativePath, kind: "remote plugin file")
            let fileURL = try validatedChildURL(named: relativePath, within: destinationURL)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: fileURL, options: .atomic)
        }
    }

    private func finishRemotePluginTemporaryWorkspace(
        _ temporaryRoot: URL,
        operationFailure: (any Error)?,
        operationCommitted: Bool
    ) throws {
        try SkillTemporaryWorkspaceCleanup(fileManager: fileManager).finish(
            temporaryRoot,
            operation: "Remote skill plugin operation",
            operationFailure: operationFailure,
            operationCommitted: operationCommitted
        )
    }

    private func remotePluginStagingDirectoryName(
        for package: RemoteSkillPluginPackage,
        index: Int
    ) -> String {
        let packageName = normalizeSkillName(package.relativePath.ifEmpty("root-plugin")).ifEmpty("plugin")
        return "\(index)-\(packageName)"
    }

    private func normalizedRemoteRepositorySource(_ url: URL) -> String {
        guard url.host?.lowercased() == "github.com" else {
            return url.absoluteString.trimmedTrailingSlash()
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else {
            return url.absoluteString.trimmedTrailingSlash()
        }
        let owner = components[0]
        let rawRepository = components[1]
        let repository = rawRepository.hasSuffix(".git") ? String(rawRepository.dropLast(4)) : rawRepository
        guard !owner.isEmpty, !repository.isEmpty else {
            return url.absoluteString.trimmedTrailingSlash()
        }
        if components.count == 2 {
            return "https://github.com/\(owner)/\(repository)"
        }
        guard components.count >= 4, components[2] == "tree" else {
            return url.absoluteString.trimmedTrailingSlash()
        }
        return "https://github.com/" + ([owner, repository] + Array(components.dropFirst(2))).joined(separator: "/")
    }
}
