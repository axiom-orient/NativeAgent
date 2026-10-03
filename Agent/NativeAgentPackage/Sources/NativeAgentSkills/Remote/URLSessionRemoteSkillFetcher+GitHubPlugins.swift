import NativeAgentDomain
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension URLSessionRemoteSkillFetcher {
    func fetchGitHubPluginPackages(
        sourceRoot: GitHubRepositoryRoot
    ) async throws -> [RemoteSkillPluginPackage] {
        do {
            if sourceRoot.path.isEmpty,
                let indexedPackages = try await fetchIndexedGitHubPluginPackages(sourceRoot: sourceRoot)
            {
                return indexedPackages
            }
            let files = try await fetchGitHubContents(
                owner: sourceRoot.owner,
                repository: sourceRoot.repository,
                reference: sourceRoot.reference,
                path: sourceRoot.path,
                relativeRoot: ""
            )
            return try discoverGitHubPluginPackages(files: files, sourceRoot: sourceRoot)
        } catch {
            return try await fetchRawGitHubPluginPackages(
                sourceRoot: sourceRoot,
                originalError: error
            )
        }
    }

    func discoverGitHubPluginPackages(
        files: [RemoteSkillPackageFile],
        sourceRoot: GitHubRepositoryRoot
) throws -> [RemoteSkillPluginPackage] {
        let filePaths = Set(files.map(\.relativePath))
        var pluginRoots = Set<String>()
        for filePath in filePaths {
                for manifestPath in SkillPluginManifestPaths.relativePaths where filePath == manifestPath || filePath.hasSuffix("/\(manifestPath)") {
                        let root = String(filePath.dropLast(manifestPath.count)).trimmedTrailingSlash()
                        pluginRoots.insert(root)
                }
        }

        let filesByPluginRoot = groupByDirectoryPrefixes(
                files,
                prefixes: pluginRoots,
                path: \.relativePath
        )
        return pluginRoots.sorted().map { pluginRoot in
                let prefix = pluginRoot.isEmpty ? "" : "\(pluginRoot)/"
                let packageFiles = (filesByPluginRoot[pluginRoot] ?? []).map { file in
                        RemoteSkillPackageFile(
                                relativePath: pluginRoot.isEmpty ? file.relativePath : String(file.relativePath.dropFirst(prefix.count)),
                                data: file.data
                        )
                }
                let location = pluginRoot.isEmpty
                        ? sourceRoot.sourceLocation
                        : "\(sourceRoot.sourceLocation)#\(pluginRoot)"
                return RemoteSkillPluginPackage(
                        sourceLocation: location,
                        relativePath: pluginRoot,
                        files: packageFiles
                )
        }
}

    func fetchIndexedGitHubPluginPackages(
        sourceRoot: GitHubRepositoryRoot
) async throws -> [RemoteSkillPluginPackage]? {
        do {
                let files = try await fetchGitHubContents(
                        owner: sourceRoot.owner,
                        repository: sourceRoot.repository,
                        reference: sourceRoot.reference,
                        path: SkillRepositoryManifest.fileName,
                        relativeRoot: SkillRepositoryManifest.fileName
                )
                guard let manifestFile = files.first(where: { $0.relativePath == SkillRepositoryManifest.fileName }) else {
                        return nil
                }
                let manifest = try JSONDecoder().decode(SkillRepositoryManifest.self, from: manifestFile.data)
                guard manifest.schemaVersion == SkillRepositoryManifest.currentSchemaVersion else {
                        throw AgentError.invalidToolCall("Unsupported NativeAgent skill repository schema: \(manifest.schemaVersion)")
                }

                let reference = try await resolveGitHubReference(sourceRoot)
                let treeFiles = try await fetchGitHubTreeFiles(
                        owner: sourceRoot.owner,
                        repository: sourceRoot.repository,
                        reference: reference
                )
                let pluginPaths = try manifest.plugins
                        .map { try GitHubRemoteSkillLocation.validateRepositoryRelativePath($0.path) }
                        .sorted()
                let entriesByPluginPath = groupByDirectoryPrefixes(
                        treeFiles,
                        prefixes: Set(pluginPaths),
                        path: \.path
                )
                var packages: [RemoteSkillPluginPackage] = []
                for pluginPath in pluginPaths {
                        let prefix = "\(pluginPath)/"
                        let pluginEntries = entriesByPluginPath[pluginPath] ?? []
                        guard !pluginEntries.isEmpty else {
                                throw AgentError.notFound("NativeAgent skill repository plugin path not found: \(pluginPath)")
                        }
                        guard pluginEntries.count <= limits.maximumFileCount else {
                                throw AgentError.budgetExceeded(
                                        "Remote plugin contains \(pluginEntries.count) files; limit is " +
                                        "\(limits.maximumFileCount)."
                                )
                        }
                        var pluginFiles: [RemoteSkillPackageFile] = []
                        for start in stride(from: 0, to: pluginEntries.count, by: 8) {
                                let end = min(start + 8, pluginEntries.count)
                                let batch = Array(pluginEntries[start..<end])
                                let fetchedBatch = try await nativeAgentBoundedConcurrentMap(
                                        batch,
                                        maximumConcurrentTasks: 8
                                ) { entry in
                                        let relativePath = String(entry.path.dropFirst(prefix.count))
                                        guard let rawURL = GitHubRemoteSkillLocation.rawURL(
                                                owner: sourceRoot.owner,
                                                repository: sourceRoot.repository,
                                                reference: reference,
                                                pathComponents: entry.path.split(separator: "/").map(String.init)
                                        ) else {
                                                throw AgentError.invalidToolCall(
                                                        "Invalid GitHub raw URL for \(entry.path)"
                                                )
                                        }
                                        let data = try await self.fetchData(
                                                from: rawURL,
                                                errorLabel: "GitHub tree file fetch"
                                        )
                                        return RemoteSkillPackageFile(
                                                relativePath: relativePath,
                                                data: data
                                        )
                                }
                                pluginFiles.append(contentsOf: fetchedBatch)
                                try validatePackageFiles(pluginFiles)
                        }
                        packages.append(RemoteSkillPluginPackage(
                                sourceLocation: "\(sourceRoot.sourceLocation)#\(pluginPath)",
                                relativePath: pluginPath,
                                files: pluginFiles
                        ))
                }
                return packages
        } catch let error as AgentError {
                if case .notFound = error {
                        return nil
                }
                throw error
        }
}

    func resolveGitHubReference(_ root: GitHubRepositoryRoot) async throws -> String {
        if let reference = root.reference {
                return reference
        }
        return try await fetchGitHubDefaultBranch(owner: root.owner, repository: root.repository)
}

    func fetchGitHubDefaultBranch(owner: String, repository: String) async throws -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)"
        guard let url = components.url else {
                throw AgentError.invalidToolCall("Invalid GitHub repository URL")
        }
        let data = try await fetchData(from: url, errorLabel: "GitHub repository metadata fetch")
        let metadata = try JSONDecoder().decode(GitHubRepositoryMetadata.self, from: data)
        guard !metadata.defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError.notFound("GitHub repository does not expose a default branch")
        }
        return metadata.defaultBranch
}

    private func fetchGitHubTreeFiles(
        owner: String,
        repository: String,
        reference: String
) async throws -> [GitHubTreeEntry] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)/git/trees/\(reference)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = components.url else {
                throw AgentError.invalidToolCall("Invalid GitHub tree URL")
        }
        let data = try await fetchData(from: url, errorLabel: "GitHub recursive tree fetch")
        let tree = try JSONDecoder().decode(GitHubTreeResponse.self, from: data)
        guard tree.truncated != true else {
                throw AgentError.invalidToolCall("GitHub recursive tree response was truncated; install a smaller plugin tree URL.")
        }
        let files = tree.tree.filter { $0.type == "blob" }
        guard files.count <= limits.maximumFileCount else {
            throw AgentError.budgetExceeded(
                "GitHub tree contains \(files.count) files; limit is " +
                    "\(limits.maximumFileCount)."
            )
        }
        return files
}

    func fetchData(from url: URL, errorLabel: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.applyGitHubHeaders(accept: url.host == "api.github.com" ? "application/vnd.github+json" : "application/octet-stream")
        let maximumByteCount =
            url.host?.lowercased() == "api.github.com"
            ? limits.maximumResponseBytes
            : limits.maximumFileBytes
        let (data, response) = try await boundedData(
            for: request,
            maximumByteCount: maximumByteCount
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AgentError.notFound("\(errorLabel) failed with status \(http.statusCode)")
        }
        return data
}

    func fetchRawGitHubPluginPackages(
        sourceRoot: GitHubRepositoryRoot,
        originalError: any Error
    ) async throws -> [RemoteSkillPluginPackage] {
        var lastError: any Error = originalError
        for reference in GitHubRemoteSkillLocation.referenceCandidates(for: sourceRoot) {
                do {
                        if sourceRoot.path.isEmpty {
                                guard let manifestData = try await fetchRawGitHubFileIfPresent(
                                        owner: sourceRoot.owner,
                                        repository: sourceRoot.repository,
                                        reference: reference,
                                        relativePath: SkillRepositoryManifest.fileName
                                ) else {
                                        continue
                                }
                                let manifest = try JSONDecoder().decode(SkillRepositoryManifest.self, from: manifestData)
                                guard manifest.schemaVersion == SkillRepositoryManifest.currentSchemaVersion else {
                                        throw AgentError.invalidToolCall("Unsupported NativeAgent skill repository schema: \(manifest.schemaVersion)")
                                }
                                var packages: [RemoteSkillPluginPackage] = []
                                for plugin in manifest.plugins.sorted(by: { $0.path < $1.path }) {
                                        packages.append(try await fetchRawGitHubPluginPackage(
                                                sourceRoot: sourceRoot,
                                                reference: reference,
                                                pluginPath: try GitHubRemoteSkillLocation.validateRepositoryRelativePath(plugin.path),
                                                repositoryRootInstall: true
                                        ))
                                }
                                return packages
                        }

                        return [
                                try await fetchRawGitHubPluginPackage(
                                        sourceRoot: sourceRoot,
                                        reference: reference,
                                        pluginPath: try GitHubRemoteSkillLocation.validateRepositoryRelativePath(sourceRoot.path),
                                        repositoryRootInstall: false
                                )
                        ]
                } catch {
                        lastError = error
                }
        }
        throw lastError
}

    func fetchRawGitHubPluginPackage(
        sourceRoot: GitHubRepositoryRoot,
        reference: String,
        pluginPath: String,
        repositoryRootInstall: Bool
) async throws -> RemoteSkillPluginPackage {
        let manifestRelativePath = "\(pluginPath)/\(SkillPluginManifestPaths.primary)"
        let manifestData = try await fetchRawGitHubFile(
                owner: sourceRoot.owner,
                repository: sourceRoot.repository,
                reference: reference,
                relativePath: manifestRelativePath
        )
        let manifest = try JSONDecoder().decode(RawGitHubSkillPluginManifest.self, from: manifestData)

        var files = [
                RemoteSkillPackageFile(relativePath: SkillPluginManifestPaths.primary, data: manifestData)
        ]
        try validatePackageFiles(files)
        for optionalFile in ["README.md", "LICENSE.md", "LICENSE.txt"] {
                if let data = try await fetchRawGitHubFileIfPresent(
                        owner: sourceRoot.owner,
                        repository: sourceRoot.repository,
                        reference: reference,
                        relativePath: "\(pluginPath)/\(optionalFile)"
                ) {
                        files.append(RemoteSkillPackageFile(relativePath: optionalFile, data: data))
                        try validatePackageFiles(files)
                }
        }

        for skill in manifest.skills {
                let skillPath = try GitHubRemoteSkillLocation.validateRepositoryRelativePath(skill.path)
                let declaredFiles = try skill.files?.map { try GitHubRemoteSkillLocation.validateRepositoryRelativePath($0) } ?? ["SKILL.md"]
                for declaredFile in declaredFiles {
                        let relativePath = "\(skillPath)/\(declaredFile)"
                        let data = try await fetchRawGitHubFile(
                                owner: sourceRoot.owner,
                                repository: sourceRoot.repository,
                                reference: reference,
                                relativePath: "\(pluginPath)/\(relativePath)"
                        )
                        files.append(RemoteSkillPackageFile(relativePath: relativePath, data: data))
                        try validatePackageFiles(files)
                }
        }

        let packageRelativePath = repositoryRootInstall ? pluginPath : ""
        let packageSource = repositoryRootInstall
                ? "\(sourceRoot.sourceLocation)#\(pluginPath)"
                : sourceRoot.sourceLocation
        return RemoteSkillPluginPackage(
                sourceLocation: packageSource,
                relativePath: packageRelativePath,
                files: files
        )
}

    func fetchRawGitHubFile(
        owner: String,
        repository: String,
        reference: String,
        relativePath: String
) async throws -> Data {
        let url = try GitHubRemoteSkillLocation.rawURL(
                owner: owner,
                repository: repository,
                reference: reference,
                relativePath: relativePath
        )
        return try await fetchData(from: url, errorLabel: "GitHub raw file fetch")
}

    func fetchRawGitHubFileIfPresent(
        owner: String,
        repository: String,
        reference: String,
        relativePath: String
) async throws -> Data? {
        let url = try GitHubRemoteSkillLocation.rawURL(
                owner: owner,
                repository: repository,
                reference: reference,
                relativePath: relativePath
        )
        var request = URLRequest(url: url)
        request.applyGitHubHeaders(accept: "application/octet-stream")
        let (data, response) = try await boundedData(
            for: request,
            maximumByteCount: limits.maximumFileBytes
        )
        if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                        return data
                }
                if http.statusCode == 404 {
                        return nil
                }
                throw AgentError.notFound("GitHub raw file fetch failed with status \(http.statusCode): \(relativePath)")
        }
        return data
}


    private func groupByDirectoryPrefixes<Element>(
        _ elements: [Element],
        prefixes: Set<String>,
        path: (Element) -> String
    ) -> [String: [Element]] {
        var grouped = Dictionary(uniqueKeysWithValues: prefixes.map { ($0, [Element]()) })
        guard !prefixes.isEmpty else { return grouped }

        for element in elements {
            let elementPath = path(element)
            if prefixes.contains("") {
                grouped["", default: []].append(element)
            }

            var searchStart = elementPath.startIndex
            while let slash = elementPath[searchStart...].firstIndex(of: "/") {
                let directoryPrefix = String(elementPath[..<slash])
                if prefixes.contains(directoryPrefix) {
                    grouped[directoryPrefix, default: []].append(element)
                }
                searchStart = elementPath.index(after: slash)
            }
        }
        return grouped
    }


    private struct SkillRepositoryManifest: Decodable {
        static let fileName = "native-agent-skill-repository.json"
        static let currentSchemaVersion = "native-agent.skill.repository/1"

        var schemaVersion: String
        var plugins: [SkillRepositoryPlugin]
    }

    private struct SkillRepositoryPlugin: Decodable {
        var path: String
}

    private struct RawGitHubSkillPluginManifest: Decodable {
        var skills: [RawGitHubSkillReference]
}

    private struct RawGitHubSkillReference: Decodable {
        var path: String
        var files: [String]?
}

    private struct GitHubRepositoryMetadata: Decodable {
        var defaultBranch: String

        private enum CodingKeys: String, CodingKey {
                case defaultBranch = "default_branch"
        }
}

    private struct GitHubTreeResponse: Decodable {
        var tree: [GitHubTreeEntry]
        var truncated: Bool?
}

    private struct GitHubTreeEntry: Decodable {
        var path: String
        var type: String
}
}
