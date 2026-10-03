import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func pluginMutationReducerProducesImmutableInstallPlan() throws {
    let originalInstallation = SkillPluginInstallation(
        id: "com.example.plugin",
        name: "Example",
        pluginVersion: "1.0.0",
        description: "Original",
        homepage: "",
        sourceLocation: "/old",
        installedSkills: [
            SkillPluginInstalledSkill(
                name: "old-skill",
                directoryName: "com-example-plugin--old-skill",
                manifestPath: "skills/old",
                selected: true
            )
        ],
        installedAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let state = SkillState(
        updatedAt: Date(timeIntervalSince1970: 1),
        selectionOverrides: ["old-skill": true],
        installedPlugins: [originalInstallation]
    )
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("new-skill", isDirectory: true)
    let managedSkill = ManagedSkill(
        name: "new-skill",
        description: "New",
        instructions: "Use it",
        builtIn: false,
        selected: false,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "plugins",
        relativePath: "plugins/com.example.plugin/skills/new/SKILL.md",
        excerpt: "Use it",
        source: ManagedSkillSource(kind: .plugin, location: "com-example-plugin--new-skill"),
        createdAt: Date(timeIntervalSince1970: 2),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let request = SkillPluginInstallRequest(
        manifest: SkillPluginManifest(
            id: "com.example.plugin",
            name: "Example",
            version: "2.0.0",
            description: "Updated",
            skills: [.init(path: "skills/new")]
        ),
        sourceLocation: "/new",
        preparedSkills: [
            SkillPluginPreparedSkill(
                manifestPath: "skills/new",
                sourceDirectory: source,
                destinationDirectoryName: "com-example-plugin--new-skill",
                skill: managedSkill
            )
        ],
        installedAt: originalInstallation.installedAt,
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    let plan = try SkillPluginMutationReducer().reduce(
        state: state,
        action: .install(requests: [request], occupiedSkillNames: ["old-skill"])
    )

    #expect(state.installedPlugins == [originalInstallation])
    #expect(plan.previousState == state)
    #expect(plan.installations.map(\.pluginVersion) == ["2.0.0"])
    #expect(plan.updatedState.installedPlugins == plan.installations)
    #expect(plan.updatedState.selectionOverrides == ["new-skill": false])
    #expect(
        plan.directoryMutations == [
            SkillDirectoryMutation(
                directoryName: "com-example-plugin--new-skill",
                contents: .copied(from: source)
            ),
            SkillDirectoryMutation(
                directoryName: "com-example-plugin--old-skill",
                contents: .absent
            ),
        ])
}

@Test
func pluginMutationReducerRejectsBatchSkillNameCollisionsBeforeEffects() throws {
    let skill = ManagedSkill(
        name: "shared",
        description: "Shared",
        instructions: "Use it",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "plugins",
        relativePath: "plugins/shared/SKILL.md",
        excerpt: "Use it",
        source: ManagedSkillSource(kind: .plugin, location: "shared")
    )
    let requests = ["one", "two"].map { id in
        SkillPluginInstallRequest(
            manifest: SkillPluginManifest(
                id: id,
                name: id,
                version: "1.0.0",
                description: id,
                skills: [.init(path: "skills/shared")]
            ),
            sourceLocation: "/\(id)",
            preparedSkills: [
                SkillPluginPreparedSkill(
                    manifestPath: "skills/shared",
                    sourceDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(id, isDirectory: true),
                    destinationDirectoryName: "\(id)--shared",
                    skill: skill
                )
            ],
            installedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    #expect(throws: AgentError.self) {
        _ = try SkillPluginMutationReducer().reduce(
            state: SkillState(),
            action: .install(requests: requests, occupiedSkillNames: [])
        )
    }
}


@Test
func skillDirectoryDigestIsDeterministicAndContentSensitive() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let destination = workspace.userSkillDirectoryURL(named: "digest-copy")
    try fileManager.createDirectory(
        at: source.appendingPathComponent("nested", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("one".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    try Data("two".utf8).write(to: source.appendingPathComponent("nested/data.txt"))
    let policy = SkillFileImportPolicy(
        fileManager: fileManager,
        pathPolicy: SkillPathPolicy(workspace: workspace)
    )

    try policy.createOrReplaceDirectory(destination)
    try policy.copySkillDirectory(from: source, to: destination)
    let sourceDigest = try policy.directoryDigest(at: source)
    #expect(try policy.directoryDigest(at: destination) == sourceDigest)

    try Data("changed".utf8).write(to: destination.appendingPathComponent("nested/data.txt"))
    #expect(try policy.directoryDigest(at: destination) != sourceDigest)
}

@Test
func workspaceTransactionReducerRejectsInvalidPhaseTransitions() throws {
    let reducer = SkillWorkspaceTransactionReducer()
    #expect(try reducer.reduce(phase: .prepared, action: .filesApplied) == .filesApplied)
    #expect(try reducer.reduce(phase: .filesApplied, action: .stateSaved) == .stateSaved)
    #expect(throws: AgentError.self) {
        _ = try reducer.reduce(phase: .prepared, action: .stateSaved)
    }
    #expect(throws: AgentError.self) {
        _ = try reducer.reduce(phase: .stateSaved, action: .filesApplied)
    }
}

@Test
func pluginInstallationRollsBackFilesystemWhenStatePersistenceFails() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let pluginRoot = root.appendingPathComponent("Plugin", isDirectory: true)
    try writeSkillPlugin(
        root: pluginRoot,
        manifest: SkillPluginManifest(
            id: "com.example.rollback",
            name: "Rollback",
            version: "1.0.0",
            description: "Must roll back",
            skills: [.init(path: "skills/rollback-skill")]
        ),
        skills: [
            "skills/rollback-skill": (
                markdown: skillMarkdown(name: "rollback-skill", description: "Rollback fixture"),
                scripts: [:]
            )
        ]
    )
    let persistence = SkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()
    await persistence.rejectFutureSaves()

    await #expect(throws: SkillStatePersistenceFixture.FixtureError.self) {
        _ = try await library.installSkillPlugin(fromDirectoryURL: pluginRoot)
    }

    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillDirectoryURL(
                named: "com-example-rollback--rollback-skill"
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
    #expect((try await persistence.boundary().load()).installedPlugins.isEmpty)
}


@Test
func workspaceTransactionRecoveryRollsBackFilesWhenStateIsPreviousRevision() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let pathPolicy = SkillPathPolicy(workspace: workspace)
    let filePolicy = SkillFileImportPolicy(fileManager: fileManager, pathPolicy: pathPolicy)
    let stateStore = SkillStateStore(fileURL: workspace.stateFileURL)
    let boundary = SkillStatePersistenceBoundary(store: stateStore)
    let previousState = SkillState(
        updatedAt: Date(timeIntervalSince1970: 1),
        selectionOverrides: ["old": true]
    )
    let updatedState = SkillState(
        updatedAt: Date(timeIntervalSince1970: 2),
        selectionOverrides: ["new": true]
    )
    try await stateStore.save(previousState)

    let directoryName = "recovery-skill"
    let targetURL = workspace.userSkillDirectoryURL(named: directoryName)
    try filePolicy.createOrReplaceDirectory(targetURL)
    try Data("old".utf8).write(to: targetURL.appendingPathComponent("SKILL.md"))
    let originalDigest = try filePolicy.directoryDigest(at: targetURL)

    let transactionRoot = workspace.userSkillsRootURL.appendingPathComponent(
        ".native-agent-skill-transaction",
        isDirectory: true
    )
    let backupURL = transactionRoot.appendingPathComponent("backup/000000", isDirectory: true)
    try filePolicy.createOrReplaceDirectory(backupURL)
    try filePolicy.copySkillDirectory(from: targetURL, to: backupURL)

    try fileManager.removeItem(at: targetURL)
    try filePolicy.createOrReplaceDirectory(targetURL)
    try Data("new".utf8).write(to: targetURL.appendingPathComponent("SKILL.md"))
    let replacementDigest = try filePolicy.directoryDigest(at: targetURL)
    let journal = SkillWorkspaceTransactionJournal(
        phase: .filesApplied,
        previousState: previousState,
        updatedState: updatedState,
        operations: [
            SkillWorkspaceTransactionOperation(
                index: 0,
                directoryName: directoryName,
                originalDigest: originalDigest,
                replacementDigest: replacementDigest
            )
        ]
    )
    try JSONEncoder.nativeAgent().encode(journal).write(
        to: transactionRoot.appendingPathComponent("journal.json"),
        options: .atomic
    )

    let executor = SkillWorkspaceTransactionExecutor(
        workspace: workspace,
        fileManager: fileManager,
        pathPolicy: pathPolicy,
        fileImportPolicy: filePolicy,
        stateStore: boundary
    )
    try await executor.recoverIfNeeded()

    #expect(try filePolicy.directoryDigest(at: targetURL) == originalDigest)
    #expect(try await stateStore.load() == previousState)
    #expect(!fileManager.fileExists(atPath: transactionRoot.path))
}

@Test
func workspaceTransactionRecoveryFinalizesFilesWhenStateIsUpdatedRevision() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let pathPolicy = SkillPathPolicy(workspace: workspace)
    let filePolicy = SkillFileImportPolicy(fileManager: fileManager, pathPolicy: pathPolicy)
    let stateStore = SkillStateStore(fileURL: workspace.stateFileURL)
    let boundary = SkillStatePersistenceBoundary(store: stateStore)
    let previousState = SkillState(updatedAt: Date(timeIntervalSince1970: 1))
    let updatedState = SkillState(
        updatedAt: Date(timeIntervalSince1970: 2),
        selectionOverrides: ["committed": true]
    )
    try await stateStore.save(updatedState)

    let directoryName = "committed-skill"
    let targetURL = workspace.userSkillDirectoryURL(named: directoryName)
    try filePolicy.createOrReplaceDirectory(targetURL)
    try Data("committed".utf8).write(to: targetURL.appendingPathComponent("SKILL.md"))
    let replacementDigest = try filePolicy.directoryDigest(at: targetURL)
    let transactionRoot = workspace.userSkillsRootURL.appendingPathComponent(
        ".native-agent-skill-transaction",
        isDirectory: true
    )
    try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
    let journal = SkillWorkspaceTransactionJournal(
        phase: .filesApplied,
        previousState: previousState,
        updatedState: updatedState,
        operations: [
            SkillWorkspaceTransactionOperation(
                index: 0,
                directoryName: directoryName,
                originalDigest: nil,
                replacementDigest: replacementDigest
            )
        ]
    )
    try JSONEncoder.nativeAgent().encode(journal).write(
        to: transactionRoot.appendingPathComponent("journal.json"),
        options: .atomic
    )

    let executor = SkillWorkspaceTransactionExecutor(
        workspace: workspace,
        fileManager: fileManager,
        pathPolicy: pathPolicy,
        fileImportPolicy: filePolicy,
        stateStore: boundary
    )
    try await executor.recoverIfNeeded()

    #expect(try filePolicy.directoryDigest(at: targetURL) == replacementDigest)
    #expect(try await stateStore.load() == updatedState)
    #expect(!fileManager.fileExists(atPath: transactionRoot.path))
}

@Test
func concurrentPluginMutationsSerializeWithoutRecoveringAnotherOperation() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let firstPlugin = root.appendingPathComponent("FirstPlugin", isDirectory: true)
    let secondPlugin = root.appendingPathComponent("SecondPlugin", isDirectory: true)
    try writeSkillPlugin(
        root: firstPlugin,
        manifest: SkillPluginManifest(
            id: "com.example.concurrent.first",
            name: "Concurrent First",
            version: "1.0.0",
            description: "First concurrent plugin",
            skills: [.init(path: "skills/concurrent-first")]
        ),
        skills: [
            "skills/concurrent-first": (
                markdown: skillMarkdown(
                    name: "concurrent-first",
                    description: "First concurrent skill"
                ),
                scripts: [:]
            )
        ]
    )
    try writeSkillPlugin(
        root: secondPlugin,
        manifest: SkillPluginManifest(
            id: "com.example.concurrent.second",
            name: "Concurrent Second",
            version: "1.0.0",
            description: "Second concurrent plugin",
            skills: [.init(path: "skills/concurrent-second")]
        ),
        skills: [
            "skills/concurrent-second": (
                markdown: skillMarkdown(
                    name: "concurrent-second",
                    description: "Second concurrent skill"
                ),
                scripts: [:]
            )
        ]
    )

    let persistence = BlockingSkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()

    let first = Task {
        try await library.installSkillPlugin(fromDirectoryURL: firstPlugin)
    }
    await persistence.waitForFirstSaveToStart()
    let second = Task {
        try await library.installSkillPlugin(fromDirectoryURL: secondPlugin)
    }

    var secondQueued = false
    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await library.accessState,
              waiting.first?.kind == .pluginMutation {
            secondQueued = true
            break
        }
        await Task.yield()
    }
    #expect(secondQueued)

    await persistence.releaseFirstSave()
    let firstInstallation = try await first.value
    let secondInstallation = try await second.value
    let snapshot = try await library.snapshot()

    #expect(
        Set(snapshot.installedPlugins.map(\.id)) == [
            firstInstallation.id,
            secondInstallation.id
        ]
    )
    #expect(await persistence.counts().saves == 2)
    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillsRootURL.appendingPathComponent(
                ".native-agent-skill-transaction",
                isDirectory: true
            ).path
        )
    )
}
