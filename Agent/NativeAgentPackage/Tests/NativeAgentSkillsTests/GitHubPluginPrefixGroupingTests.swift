import Foundation
import Testing

@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func githubPluginDiscoveryGroupsNestedRootsWithoutChangingFileOrder() throws {
    let repositoryURL = try #require(URL(string: "https://github.com/example/repository"))
    let sourceRoot = GitHubRepositoryRoot(
        owner: "example",
        repository: "repository",
        reference: "main",
        pathComponents: [],
        originalURL: repositoryURL
    )
    let files = [
        remoteFile("plugins/parent/child/a.txt"),
        remoteFile("plugins/parent/z.txt"),
        remoteFile("plugins/parent/child/native-agent-skill-plugin.json"),
        remoteFile("outside.txt"),
        remoteFile("plugins/parent/native-agent-skill-plugin.json"),
    ]

    let packages = try URLSessionRemoteSkillFetcher().discoverGitHubPluginPackages(
        files: files,
        sourceRoot: sourceRoot
    )

    #expect(packages.map(\.relativePath) == ["plugins/parent", "plugins/parent/child"])
    #expect(
        packages[0].files.map(\.relativePath) == [
            "child/a.txt",
            "z.txt",
            "child/native-agent-skill-plugin.json",
            "native-agent-skill-plugin.json",
        ]
    )
    #expect(
        packages[1].files.map(\.relativePath) == [
            "a.txt",
            "native-agent-skill-plugin.json",
        ]
    )
}

private func remoteFile(_ path: String) -> RemoteSkillPackageFile {
    RemoteSkillPackageFile(relativePath: path, data: Data(path.utf8))
}
