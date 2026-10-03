import NativeAgentDomain
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension URLSessionRemoteSkillFetcher {
    func fetchGitHubSkillPackage(root: GitHubSkillRoot) async throws -> RemoteSkillPackage {
        let files = try await fetchGitHubContents(
            owner: root.owner,
            repository: root.repository,
            reference: root.reference,
            path: root.path,
            relativeRoot: ""
        )
        guard files.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw AgentError.notFound("Remote GitHub skill package does not contain SKILL.md")
        }
        return RemoteSkillPackage(files: files)
    }

    func fetchGitHubContents(
        owner: String,
        repository: String,
        reference: String?,
        path: String,
        relativeRoot: String,
        depth: Int = 0
    ) async throws -> [RemoteSkillPackageFile] {
        guard depth <= limits.maximumDirectoryDepth else {
            throw AgentError.budgetExceeded(
                "Remote skill directory depth exceeds \(limits.maximumDirectoryDepth)."
            )
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)/contents" + (path.isEmpty ? "" : "/\(path)")
        if let reference {
            components.queryItems = [URLQueryItem(name: "ref", value: reference)]
        }
        guard let url = components.url else {
            throw AgentError.invalidToolCall("Invalid GitHub skill URL")
        }

        var request = URLRequest(url: url)
        request.applyGitHubHeaders(accept: "application/vnd.github+json")
        let (data, response) = try await boundedData(
            for: request,
            maximumByteCount: limits.maximumResponseBytes
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentError.notFound("GitHub contents fetch failed with status \(http.statusCode)")
        }

        let decoder = JSONDecoder()
        if let entries = try? decoder.decode([GitHubContentEntry].self, from: data) {
            let actionableEntries = entries
                .filter { $0.type == "file" || $0.type == "dir" }
                .sorted(by: { $0.name < $1.name })
            guard actionableEntries.count <= limits.maximumEntriesPerDirectory else {
                throw AgentError.budgetExceeded(
                    "Remote skill directory contains \(actionableEntries.count) entries; " +
                        "limit is \(limits.maximumEntriesPerDirectory)."
                )
            }
            let fileEntries = actionableEntries.filter { $0.type == "file" }
            guard fileEntries.count <= limits.maximumFileCount else {
                throw AgentError.budgetExceeded(
                    "Remote skill directory contains \(fileEntries.count) files; limit is " +
                        "\(limits.maximumFileCount)."
                )
            }
            var fetchedFiles: [RemoteSkillPackageFile] = []
            for start in stride(from: 0, to: fileEntries.count, by: 8) {
                let end = min(start + 8, fileEntries.count)
                let batch = Array(fileEntries[start..<end])
                let fetchedBatch = try await nativeAgentBoundedConcurrentMap(
                    batch,
                    maximumConcurrentTasks: 8
                ) { entry in
                    let relativePath =
                        relativeRoot.isEmpty ? entry.name : "\(relativeRoot)/\(entry.name)"
                    return try await self.fetchGitHubFile(
                        entry: entry,
                        relativePath: relativePath
                    )
                }
                fetchedFiles.append(contentsOf: fetchedBatch)
                try validatePackageFiles(fetchedFiles)
            }
            var fileByPath: [String: RemoteSkillPackageFile] = [:]
            for file in fetchedFiles {
                guard fileByPath.updateValue(file, forKey: file.relativePath) == nil else {
                    throw AgentError.invariantViolation(
                        "GitHub contents returned duplicate file path: \(file.relativePath)"
                    )
                }
            }

            var results: [RemoteSkillPackageFile] = []
            for entry in actionableEntries {
                let relativePath = relativeRoot.isEmpty ? entry.name : "\(relativeRoot)/\(entry.name)"
                if entry.type == "file" {
                    guard let file = fileByPath[relativePath] else {
                        throw AgentError.invariantViolation(
                            "GitHub contents fetch did not produce file: \(relativePath)"
                        )
                    }
                    results.append(file)
                } else {
                    results.append(contentsOf: try await fetchGitHubContents(
                        owner: owner,
                        repository: repository,
                        reference: reference,
                        path: entry.path,
                        relativeRoot: relativePath,
                        depth: depth + 1
                    ))
                }
                try validatePackageFiles(results)
            }
            return results
        }

        let entry = try decoder.decode(GitHubContentEntry.self, from: data)
        guard entry.type == "file" else { return [] }
        return [
            try await fetchGitHubFile(
                entry: entry,
                relativePath: relativeRoot.ifEmpty(entry.name)
            )
        ]
    }

    func fetchGitHubFile(
        entry: GitHubContentEntry,
        relativePath: String
    ) async throws -> RemoteSkillPackageFile {
        guard let downloadURLString = entry.downloadURL,
            let downloadURL = URL(string: downloadURLString)
        else {
            throw AgentError.notFound("GitHub file does not expose a download URL: \(entry.path)")
        }
        var request = URLRequest(url: downloadURL)
        request.applyGitHubHeaders(accept: "application/octet-stream")
        let (data, response) = try await boundedData(
            for: request,
            maximumByteCount: limits.maximumFileBytes
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentError.notFound("GitHub file fetch failed with status \(http.statusCode): \(entry.path)")
        }
        return RemoteSkillPackageFile(relativePath: relativePath, data: data)
    }
}
