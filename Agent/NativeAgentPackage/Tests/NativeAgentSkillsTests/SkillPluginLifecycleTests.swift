import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func installSkillPluginCopiesSkillsAndTracksInstallation() async throws {
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
            id: "com.example.writer-pack",
            name: "Writer Pack",
            version: "1.0.0",
            description: "Writing helpers",
            homepage: "https://example.com/writer-pack",
            skills: [
                .init(path: "skills/summarizer"),
                .init(path: "skills/reviewer", selected: false),
            ]
        ),
        skills: [
            "skills/summarizer": (
                markdown: skillMarkdown(name: "summarizer", description: "Summarizes text"),
                scripts: ["index.html": "<html>summary</html>"]
            ),
            "skills/reviewer": (
                markdown: skillMarkdown(name: "reviewer", description: "Reviews text"),
                scripts: [:]
            ),
        ]
    )

    let installation = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    let snapshot = try await library.snapshot()
    let summarizer = try #require(snapshot.skills.first { $0.name == "summarizer" })
    let reviewer = try #require(snapshot.skills.first { $0.name == "reviewer" })

    #expect(installation.id == "com.example.writer-pack")
    #expect(installation.installedSkills.map(\.name).sorted() == ["reviewer", "summarizer"])
    #expect(snapshot.installedPlugins.map(\.id) == ["com.example.writer-pack"])
    #expect(summarizer.source.kind == .plugin)
    #expect(summarizer.source.location == "com-example-writer-pack--summarizer")
    #expect(summarizer.group == "plugins")
    #expect(summarizer.selected)
    #expect(summarizer.executionSupport == .unavailableOnMobile)
    #expect(summarizer.executionSupportReason.contains("unavailable on iOS"))
    #expect(reviewer.source.kind == .plugin)
    #expect(!reviewer.selected)
    #expect(reviewer.executionSupport == .unavailableOnMobile)

    let scriptURL = try await library.resolveScriptURL(for: summarizer, scriptName: "index.html")
    #expect(FileManager.default.fileExists(atPath: scriptURL.path))

    let installedPlugins = try await library.installedSkillPlugins()
    #expect(installedPlugins == snapshot.installedPlugins)
}

@Test
func installSkillPluginRejectsSkillNameThatDoesNotMatchManifestDirectory() async throws {
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
            id: "com.example.identity-pack",
            name: "Identity Pack",
            version: "1.0.0",
            description: "Identity validation",
            skills: [.init(path: "skills/declared-directory")]
        ),
        skills: [
            "skills/declared-directory": (
                markdown: skillMarkdown(name: "different-name", description: "Must be rejected"),
                scripts: [:]
            )
        ]
    )

    await #expect(throws: AgentError.self) {
        _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    }
    #expect((try await library.installedSkillPlugins()).isEmpty)
}

@Test
func installSkillPluginKeepsNativeIntentOnlySkillsExecutableAvailable() async throws {
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
            id: "com.example.native-intent-pack",
            name: "Native Intent Pack",
            version: "1.0.0",
            description: "Native host intent skill",
            skills: [.init(path: "skills/paper-search")]
        ),
        skills: [
            "skills/paper-search": (
                markdown: """
                ---
                name: paper-search
                description: Searches papers through a native NativeAgent host intent.
                ---

                Call `run_intent` with `scientific.paper_search` and summarize the structured result.
                """,
                scripts: [:]
            )
        ]
    )

    _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    let skill = try #require(
        (try await library.snapshot()).skills.first { $0.name == "paper-search" })

    #expect(skill.source.kind == .plugin)
    #expect(skill.executionSupport == .available)
    #expect(skill.isExecutionAvailable)
}

@Test
func installSkillPluginAllowsNativeMobileReplacementForExternalRuntimeText() async throws {
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
            id: "com.example.numeric-pack",
            name: "Numeric Pack",
            version: "1.0.0",
            description: "Native numeric replacement",
            skills: [.init(path: "skills/matlab-local")]
        ),
        skills: [
            "skills/matlab-local": (
                markdown: """
                ---
                name: matlab-local
                description: Converts MATLAB or Python numeric requests to NativeAgent native Swift host intents.
                native-agent-mobile-native-execution: true
                ---

                Use `run_intent` with `scientific.numeric_eval` for matrix and vector operations.
                Do not run matlab scripts or python scripts on iOS.
                """,
                scripts: [:]
            )
        ]
    )

    _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    let skill = try #require(
        (try await library.snapshot()).skills.first { $0.name == "matlab-local" })

    #expect(skill.executionSupport == .available)
    #expect(skill.isExecutionAvailable)
}

@Test
func uninstallSkillPluginRemovesInstalledSkillsAndSelectionState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let library = SkillLibrary(workspace: workspace)
    let pluginRoot = root.appendingPathComponent("Plugin", isDirectory: true)
    try writeSkillPlugin(
        root: pluginRoot,
        manifest: SkillPluginManifest(
            id: "com.example.device-pack",
            name: "Device Pack",
            version: "1.0.0",
            description: "Device helpers"
        ),
        skills: [
            "skills/torch-helper": (
                markdown: skillMarkdown(name: "torch-helper", description: "Controls torch"),
                scripts: [:]
            )
        ]
    )

    let installation = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    let installedSkill = try #require(installation.installedSkills.first)
    let installedDirectory = workspace.userSkillDirectoryURL(named: installedSkill.directoryName)
    #expect(FileManager.default.fileExists(atPath: installedDirectory.path))

    try await library.uninstallSkillPlugin(id: "com.example.device-pack")

    let snapshot = try await library.snapshot()
    #expect(snapshot.installedPlugins.isEmpty)
    #expect(!snapshot.skills.contains { $0.name == "torch-helper" })
    #expect(!FileManager.default.fileExists(atPath: installedDirectory.path))
}

@Test
func installRemoteSkillPluginsFromGitHubRepositoryAndUninstallByRepositoryURL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let repositoryURL = "https://github.com/AxiomOrient/skillsPlugin"
    let repository = RemoteSkillPluginRepository(
        sourceLocation: repositoryURL,
        pluginPackages: [
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/scientific-documents",
                relativePath: "plugins/scientific-documents",
                manifest: SkillPluginManifest(
                    id: "io.axiomorient.nativeagent.scientific.documents",
                    name: "Scientific Documents",
                    version: "0.1.0",
                    description: "Documents",
                    homepage: "\(repositoryURL)/tree/main/plugins/scientific-documents",
                    skills: [.init(path: "skills/markitdown")]
                ),
                skills: [
                    "skills/markitdown": """
                    ---
                    name: markitdown
                    description: Converts supported text-like artifacts to Markdown through NativeAgent native intents.
                    ---

                    Call `run_intent` with `scientific.document_to_markdown`.
                    """
                ]
            ),
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/scientific-compute-remote",
                relativePath: "plugins/scientific-compute-remote",
                manifest: SkillPluginManifest(
                    id: "io.axiomorient.nativeagent.scientific.compute.remote",
                    name: "Scientific Compute Remote",
                    version: "0.1.0",
                    description: "Remote compute",
                    homepage: "\(repositoryURL)/tree/main/plugins/scientific-compute-remote",
                    skills: [.init(path: "skills/rdkit")]
                ),
                skills: [
                    "skills/rdkit": """
                    ---
                    name: rdkit
                    description: Routes Python chemistry work to remote compute preflight.
                    ---

                    Call `run_intent` with `scientific.remote_job_preflight`.
                    """
                ]
            ),
        ]
    )
    let persistence = SkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        remoteFetcher: StaticRemoteSkillFetcher(markdown: "", pluginRepository: repository),
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )

    let installations = try await library.installSkillPlugins(fromRemoteRepositoryURL: repositoryURL)
    let snapshot = try await library.snapshot()
    #expect(await persistence.recordedSaveAttemptCount() == 1)

    #expect(
        installations.map(\.id).sorted() == [
            "io.axiomorient.nativeagent.scientific.compute.remote",
            "io.axiomorient.nativeagent.scientific.documents",
        ])
    #expect(snapshot.installedPlugins.count == 2)
    #expect(
        snapshot.skills.filter { $0.source.kind == .plugin }.map(\.name).sorted() == [
            "markitdown", "rdkit",
        ])
    #expect(
        snapshot.installedPlugins.allSatisfy {
            $0.sourceLocation.hasPrefix("\(repositoryURL)#plugins/")
        })

    let removedIDs = try await library.uninstallSkillPlugins(fromRemoteRepositoryURL: repositoryURL)
    let finalSnapshot = try await library.snapshot()
    #expect(await persistence.recordedSaveAttemptCount() == 2)

    #expect(removedIDs.sorted() == installations.map(\.id).sorted())
    #expect(finalSnapshot.installedPlugins.isEmpty)
    #expect(
        !finalSnapshot.skills.contains {
            $0.source.kind == .plugin && ($0.name == "markitdown" || $0.name == "rdkit")
        })
}

@Test
func installRemoteSkillPluginsRollsBackEarlierPackagesWhenLaterPackageFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let repositoryURL = "https://github.com/AxiomOrient/skillsPlugin"
    let repository = RemoteSkillPluginRepository(
        sourceLocation: repositoryURL,
        pluginPackages: [
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/one",
                relativePath: "plugins/one",
                manifest: SkillPluginManifest(
                    id: "io.axiomorient.nativeagent.one",
                    name: "One",
                    version: "0.1.0",
                    description: "First package",
                    skills: [.init(path: "skills/shared-skill")]
                ),
                skills: [
                    "skills/shared-skill": """
                    ---
                    name: shared-skill
                    description: First install succeeds before the second package fails.
                    ---

                    Explain the shared skill.
                    """
                ]
            ),
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/two",
                relativePath: "plugins/two",
                manifest: SkillPluginManifest(
                    id: "io.axiomorient.nativeagent.two",
                    name: "Two",
                    version: "0.1.0",
                    description: "Second package collides",
                    skills: [.init(path: "skills/shared-skill")]
                ),
                skills: [
                    "skills/shared-skill": """
                    ---
                    name: shared-skill
                    description: Duplicate name should fail the repository install.
                    ---

                    Explain the duplicate skill.
                    """
                ]
            ),
        ]
    )
    let library = SkillLibrary(
        workspace: workspace,
        remoteFetcher: StaticRemoteSkillFetcher(markdown: "", pluginRepository: repository)
    )

    await #expect(throws: AgentError.self) {
        _ = try await library.installSkillPlugins(fromRemoteRepositoryURL: repositoryURL)
    }

    let snapshot = try await library.snapshot()
    #expect(snapshot.installedPlugins.isEmpty)
    #expect(!snapshot.skills.contains { $0.source.kind == .plugin && $0.name == "shared-skill" })
}

@Test
func installRemoteSkillPluginBatchRollsBackAllDirectoriesWhenStateSaveFails() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let repositoryURL = "https://github.com/example/atomic-skills"
    let repository = RemoteSkillPluginRepository(
        sourceLocation: repositoryURL,
        pluginPackages: [
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/one",
                relativePath: "plugins/one",
                manifest: SkillPluginManifest(
                    id: "com.example.atomic.one",
                    name: "Atomic One",
                    version: "1.0.0",
                    description: "First atomic plugin",
                    skills: [.init(path: "skills/atomic-one")]
                ),
                skills: [
                    "skills/atomic-one": skillMarkdown(
                        name: "atomic-one",
                        description: "First atomic skill"
                    )
                ]
            ),
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/two",
                relativePath: "plugins/two",
                manifest: SkillPluginManifest(
                    id: "com.example.atomic.two",
                    name: "Atomic Two",
                    version: "1.0.0",
                    description: "Second atomic plugin",
                    skills: [.init(path: "skills/atomic-two")]
                ),
                skills: [
                    "skills/atomic-two": skillMarkdown(
                        name: "atomic-two",
                        description: "Second atomic skill"
                    )
                ]
            )
        ]
    )
    let persistence = SkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        remoteFetcher: StaticRemoteSkillFetcher(markdown: "", pluginRepository: repository),
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()
    await persistence.rejectFutureSaves()

    await #expect(throws: SkillStatePersistenceFixture.FixtureError.self) {
        _ = try await library.installSkillPlugins(fromRemoteRepositoryURL: repositoryURL)
    }

    #expect(await persistence.recordedSaveAttemptCount() == 1)
    #expect((try await persistence.boundary().load()).installedPlugins.isEmpty)
    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillDirectoryURL(
                named: "com-example-atomic-one--atomic-one"
            ).path
        )
    )
    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillDirectoryURL(
                named: "com-example-atomic-two--atomic-two"
            ).path
        )
    )
    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillsRootURL.appendingPathComponent(
                ".native-agent-skill-transaction",
                isDirectory: true
            ).path
        )
    )
}

@Test
func uninstallRemoteSkillPluginsMatchesGitSuffixRepositoryURL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let repositoryURL = "https://github.com/AxiomOrient/skillsPlugin"
    let repository = RemoteSkillPluginRepository(
        sourceLocation: repositoryURL,
        pluginPackages: [
            try remotePluginPackage(
                sourceLocation: "\(repositoryURL)#plugins/scientific-documents",
                relativePath: "plugins/scientific-documents",
                manifest: SkillPluginManifest(
                    id: "io.axiomorient.nativeagent.scientific.documents",
                    name: "Scientific Documents",
                    version: "0.1.0",
                    description: "Documents",
                    skills: [.init(path: "skills/markitdown")]
                ),
                skills: [
                    "skills/markitdown": """
                    ---
                    name: markitdown
                    description: Converts supported text-like artifacts to Markdown.
                    ---

                    Call `run_intent` with `scientific.document_to_markdown`.
                    """
                ]
            )
        ]
    )
    let library = SkillLibrary(
        workspace: workspace,
        remoteFetcher: StaticRemoteSkillFetcher(markdown: "", pluginRepository: repository)
    )

    _ = try await library.installSkillPlugins(fromRemoteRepositoryURL: repositoryURL)
    let removedIDs = try await library.uninstallSkillPlugins(
        fromRemoteRepositoryURL: "\(repositoryURL).git")

    #expect(removedIDs == ["io.axiomorient.nativeagent.scientific.documents"])
    #expect((try await library.snapshot()).installedPlugins.isEmpty)
}
