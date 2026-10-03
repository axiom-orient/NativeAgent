import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func fetchGitHubSkillPluginRepositoryUsesRepositoryIndexManifest() async throws {
    let repositoryURL = "https://github.com/AxiomOrient/skillsPlugin"
    var responses: [String: (status: Int, data: Data)] = [:]
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/native-agent-skill-repository.json"] = (
            200,
            githubContentFileJSON(
                name: "native-agent-skill-repository.json",
                path: "native-agent-skill-repository.json",
                downloadURL: "https://raw.example.test/native-agent-skill-repository.json"
            )
        )
    responses["https://raw.example.test/native-agent-skill-repository.json"] = (
        200,
        Data(
            """
            {
              "schemaVersion": "native-agent.skill.repository/1",
              "plugins": [
                {"path": "plugins/scientific-documents"},
                {"path": "plugins/scientific-compute-remote"}
              ]
            }
            """.utf8)
    )
    responses["https://api.github.com/repos/AxiomOrient/skillsPlugin"] = (
        200,
        Data(#"{"default_branch":"main"}"#.utf8)
    )
    var treeEntries: [(path: String, type: String)] = []
    addGitHubPluginResponses(
        to: &responses,
        treeEntries: &treeEntries,
        pluginPath: "plugins/scientific-documents",
        skillName: "markitdown",
        skillDescription: "Converts mobile-safe text-like artifacts to Markdown."
    )
    addGitHubPluginResponses(
        to: &responses,
        treeEntries: &treeEntries,
        pluginPath: "plugins/scientific-compute-remote",
        skillName: "rdkit",
        skillDescription: "Routes scientific Python work to remote compute preflight."
    )
    responses["https://api.github.com/repos/AxiomOrient/skillsPlugin/git/trees/main?recursive=1"] = (
        200,
        githubTreeJSON(entries: treeEntries)
    )
    StaticHTTPURLProtocol.configure(responses: responses)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StaticHTTPURLProtocol.self]
    let fetcher = URLSessionRemoteSkillFetcher(session: URLSession(configuration: configuration))

    let repository = try await fetcher.fetchSkillPluginRepository(
        repositoryURL: try #require(URL(string: repositoryURL)))
    let requestedURLs = StaticHTTPURLProtocol.requestedURLs()

    #expect(repository.sourceLocation == repositoryURL)
    #expect(
        repository.pluginPackages.map(\.relativePath) == [
            "plugins/scientific-compute-remote",
            "plugins/scientific-documents",
        ])
    #expect(
        repository.pluginPackages.allSatisfy {
            $0.sourceLocation.hasPrefix("\(repositoryURL)#plugins/")
        })
    #expect(
        repository.pluginPackages.allSatisfy { package in
            package.files.contains { $0.relativePath == "native-agent-skill-plugin.json" }
                && package.files.contains { $0.relativePath.hasSuffix("/SKILL.md") }
        })
    #expect(!requestedURLs.contains("https://api.github.com/repos/AxiomOrient/skillsPlugin/contents"))
    #expect(
        requestedURLs.contains(
            "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/native-agent-skill-repository.json"))
    #expect(
        requestedURLs.contains(
            "https://api.github.com/repos/AxiomOrient/skillsPlugin/git/trees/main?recursive=1"))
}

@Test
func fetchGitHubSkillPluginRepositoryDiscoversSingleTreePluginManifest() async throws {
    let repositoryURL =
        "https://github.com/AxiomOrient/skillsPlugin/tree/main/plugins/scientific-documents"
    var responses: [String: (status: Int, data: Data)] = [:]
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/native-agent-skill-repository.json?ref=main"
    ] = (
        404,
        Data("{}".utf8)
    )
    var treeEntries: [(path: String, type: String)] = []
    addGitHubPluginResponses(
        to: &responses,
        treeEntries: &treeEntries,
        pluginPath: "plugins/scientific-documents",
        skillName: "markitdown",
        skillDescription: "Converts mobile-safe text-like artifacts to Markdown."
    )
    StaticHTTPURLProtocol.configure(responses: responses)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StaticHTTPURLProtocol.self]
    let fetcher = URLSessionRemoteSkillFetcher(session: URLSession(configuration: configuration))

    let repository = try await fetcher.fetchSkillPluginRepository(
        repositoryURL: try #require(URL(string: repositoryURL)))

    #expect(repository.sourceLocation == repositoryURL)
    #expect(repository.pluginPackages.map(\.relativePath) == [""])
    let package = try #require(repository.pluginPackages.first)
    #expect(package.sourceLocation == repositoryURL)
    #expect(package.files.contains { $0.relativePath == "native-agent-skill-plugin.json" })
    #expect(package.files.contains { $0.relativePath == "skills/markitdown/SKILL.md" })
}

@Test
func fetchGitHubSkillPluginRepositoryFallsBackToRawFilesWhenAPIIsForbidden() async throws {
    let repositoryURL =
        "https://github.com/AxiomOrient/skillsPlugin/tree/main/plugins/raw-fallback-documents"
    var responses: [String: (status: Int, data: Data)] = [:]
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/plugins/raw-fallback-documents?ref=main"
    ] = (
        403,
        Data(#"{"message":"API rate limit exceeded"}"#.utf8)
    )
    responses[
        "https://raw.githubusercontent.com/AxiomOrient/skillsPlugin/main/plugins/raw-fallback-documents/native-agent-skill-plugin.json"
    ] = (
        200,
        Data(
            """
            {
              "schemaVersion": "\(SkillPluginManifest.supportedSchemaVersion)",
              "id": "io.axiomorient.nativeagent.scientific.documents",
              "name": "Scientific Documents",
              "version": "0.1.0",
              "description": "Document skills",
              "skills": [
                {
                  "path": "skills/markitdown",
                  "files": [
                    "SKILL.md",
                    "references/file_formats.md"
                  ]
                }
              ]
            }
            """.utf8)
    )
    responses[
        "https://raw.githubusercontent.com/AxiomOrient/skillsPlugin/main/plugins/raw-fallback-documents/README.md"
    ] = (
        200,
        Data("# Scientific Documents".utf8)
    )
    responses[
        "https://raw.githubusercontent.com/AxiomOrient/skillsPlugin/main/plugins/raw-fallback-documents/skills/markitdown/SKILL.md"
    ] = (
        200,
        Data(
            """
            ---
            name: markitdown
            description: Converts mobile-safe text-like artifacts to Markdown.
            ---

            Call `run_intent` from NativeAgent.
            """.utf8)
    )
    responses[
        "https://raw.githubusercontent.com/AxiomOrient/skillsPlugin/main/plugins/raw-fallback-documents/skills/markitdown/references/file_formats.md"
    ] = (
        200,
        Data("# File formats".utf8)
    )
    StaticHTTPURLProtocol.configure(responses: responses)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StaticHTTPURLProtocol.self]
    let fetcher = URLSessionRemoteSkillFetcher(session: URLSession(configuration: configuration))

    let repository = try await fetcher.fetchSkillPluginRepository(
        repositoryURL: try #require(URL(string: repositoryURL)))
    let package = try #require(repository.pluginPackages.first)

    #expect(repository.sourceLocation == repositoryURL)
    #expect(repository.pluginPackages.map(\.relativePath) == [""])
    #expect(package.files.contains { $0.relativePath == "native-agent-skill-plugin.json" })
    #expect(package.files.contains { $0.relativePath == "skills/markitdown/SKILL.md" })
    #expect(
        package.files.contains { $0.relativePath == "skills/markitdown/references/file_formats.md" })
}

@Test
func installSkillPluginRejectsSkillNameCollisions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    _ = try await library.addCustomTextSkill(
        name: "summarizer",
        description: "Existing skill",
        instructions: "Existing",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: ""
    )

    let pluginRoot = root.appendingPathComponent("Plugin", isDirectory: true)
    try writeSkillPlugin(
        root: pluginRoot,
        manifest: SkillPluginManifest(
            id: "com.example.writer-pack",
            name: "Writer Pack",
            version: "1.0.0",
            description: "Writing helpers",
            skills: [.init(path: "skills/summarizer")]
        ),
        skills: [
            "skills/summarizer": (
                markdown: skillMarkdown(name: "summarizer", description: "Summarizes text"),
                scripts: [:]
            )
        ]
    )

    await #expect(throws: AgentError.self) {
        _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    }
}

@Test
func installSkillPluginRejectsTraversalSkillPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    let pluginRoot = root.appendingPathComponent("Plugin", isDirectory: true)
    try writeSkillPlugin(
        root: pluginRoot,
        manifest: SkillPluginManifest(
            id: "com.example.bad-pack",
            name: "Bad Pack",
            version: "1.0.0",
            description: "Bad helpers",
            skills: [.init(path: "../outside")]
        ),
        skills: [:]
    )

    await #expect(throws: AgentError.self) {
        _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    }
}

@Test
func installSkillPluginRequiresNativeAgentManifestName() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    let pluginRoot = root.appendingPathComponent("Plugin", isDirectory: true)
    let foreignRoot = pluginRoot.appendingPathComponent(".codex-plugin", isDirectory: true)
    try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
    let foreignManifest = SkillPluginManifest(
        id: "com.example.foreign-pack",
        name: "Foreign Pack",
        version: "1.0.0",
        description: "A foreign manifest name must not define an NativeAgent plugin.",
        skills: [.init(path: "skills/foreign")]
    )
    try JSONEncoder.nativeAgent().encode(foreignManifest)
        .write(to: foreignRoot.appendingPathComponent("plugin.json"), options: .atomic)

    await #expect(throws: AgentError.self) {
        _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    }
}
@Test
func loadSkillPropagatesSupportingFileReadFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "native-agent-load-skill-supporting-file-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = SkillLibrary(
        workspace: SkillWorkspace(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    let skill = try await library.addCustomTextSkill(
        name: "Broken Support",
        description: "Exercises load failure propagation",
        instructions: "Read supporting context",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: ""
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: RecordingScriptRunner(response: SkillScriptResponse(result: "unused")),
        intentService: NoopIntentService(),
        supportingFileLoader: { _ in throw SupportingFileFixtureError.unavailable }
    )

    await #expect(throws: SupportingFileFixtureError.self) {
        _ = try await runtime.loadSkill(named: skill.name, callID: "load-broken-support")
    }
}

@Test
func githubRemoteSkillLocationSeparatesURLPolicyFromNetworkEffects() throws {
    let treeURL = try #require(
        URL(string: "https://github.com/AxiomOrient/skills/tree/main/skills/reviewer"))
    let treeRoot = try #require(GitHubRemoteSkillLocation.skillRoot(from: treeURL))
    #expect(treeRoot.owner == "AxiomOrient")
    #expect(treeRoot.repository == "skills")
    #expect(treeRoot.reference == "main")
    #expect(treeRoot.path == "skills/reviewer")
    #expect(
        GitHubRemoteSkillLocation.skillMarkdownURL(from: treeURL).absoluteString
            == "https://raw.githubusercontent.com/AxiomOrient/skills/main/skills/reviewer/SKILL.md")

    let repositoryURL = try #require(URL(string: "https://github.com/AxiomOrient/skills.git"))
    let repository = try #require(GitHubRemoteSkillLocation.repositoryRoot(from: repositoryURL))
    #expect(repository.sourceLocation == "https://github.com/AxiomOrient/skills")
    #expect(GitHubRemoteSkillLocation.referenceCandidates(for: repository) == ["main", "master"])

    #expect(throws: AgentError.self) {
        _ = try GitHubRemoteSkillLocation.validateRepositoryRelativePath("../escape")
    }
}

@Test
func fetchGitHubContentsRejectsDuplicateFilePathsWithoutRuntimeTrap() async throws {
    let contentsURL = "https://api.github.com/repos/example/repository/contents?ref=main"
    let rawURL = "https://raw.example.test/duplicate.txt"
    StaticHTTPURLProtocol.configure(responses: [
        contentsURL: (
            200,
            githubContentDirectoryJSON(entries: [
                ("duplicate.txt", "duplicate.txt", "file", rawURL),
                ("duplicate.txt", "duplicate.txt", "file", rawURL),
            ])
        ),
        rawURL: (200, Data("duplicate".utf8)),
    ])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StaticHTTPURLProtocol.self]
    let fetcher = URLSessionRemoteSkillFetcher(session: URLSession(configuration: configuration))

    await #expect(throws: AgentError.self) {
        _ = try await fetcher.fetchGitHubContents(
            owner: "example",
            repository: "repository",
            reference: "main",
            path: "",
            relativeRoot: ""
        )
    }
}
