import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

@Test
func instructionAssemblyAugmentorMergesBasePromptEnvironmentAndInstructionFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let global = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("md")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "repo rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "local rules".write(to: root.appendingPathComponent("AGENTS.local.md"), atomically: true, encoding: .utf8)
    try "global rules".write(to: global, atomically: true, encoding: .utf8)

    let augmentor = InstructionAssemblyPromptAugmentor()
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
            sessionID: "session-1",
            basePrompt: "Base system prompt",
            userPrompt: "hello",
            metadata: [
                PromptInstructionMetadataKeys.workingDirectory: .string(root.path),
                PromptInstructionMetadataKeys.platform: .string("iOS"),
                PromptInstructionMetadataKeys.date: .string("2026-04-11"),
                PromptInstructionMetadataKeys.globalInstructionsPath: .string(global.path)
            ]
        )
    )

    let rendered = try #require(prompt)
    #expect(rendered.contains("Base system prompt"))
    #expect(rendered.contains("Environment:\n- Working directory: \(root.path)\n- Platform: iOS\n- Date: 2026-04-11"))
    #expect(rendered.contains("Project instructions (AGENTS.md):\nrepo rules"))
    #expect(rendered.contains("Local instructions (AGENTS.local.md):\nlocal rules"))
    #expect(rendered.contains("Global instructions (\(global.path)):\nglobal rules"))
    #expect(rendered.range(of: "Base system prompt")!.lowerBound < rendered.range(of: "Environment:")!.lowerBound)
    #expect(rendered.range(of: "Environment:")!.lowerBound < rendered.range(of: "Project instructions (AGENTS.md):")!.lowerBound)
}

@Test
func instructionAssemblyAugmentorPrefersFirstKnownProjectInstructionFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "agents wins".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "claude loses".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

    let augmentor = InstructionAssemblyPromptAugmentor()
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
            sessionID: "session-2",
            userPrompt: "hello",
            metadata: [
                PromptInstructionMetadataKeys.workingDirectory: .string(root.path)
            ]
        )
    )

    let rendered = try #require(prompt)
    #expect(rendered.contains("Project instructions (AGENTS.md):\nagents wins"))
    #expect(rendered.contains("claude loses") == false)
}

@Test
func sessionCoordinatorDefaultPromptAugmentorBuildsInstructionAssemblyFromMetadata() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspace = tempRoot.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try "repo rules".write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "ok")
    ])
    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: []
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "hello",
        systemPrompt: "Base system prompt",
        metadata: [
            PromptInstructionMetadataKeys.workingDirectory: .string(workspace.path),
            PromptInstructionMetadataKeys.platform: .string("iOS")
        ]
    )

    let systemMessage = try #require(snapshot.messages.first)
    #expect(systemMessage.role == .system)
    #expect(systemMessage.content.contains("Base system prompt"))
    #expect(systemMessage.content.contains("Environment:\n- Working directory: \(workspace.path)\n- Platform: iOS"))
    #expect(systemMessage.content.contains("Project instructions (AGENTS.md):\nrepo rules"))
}


@Test
func instructionAssemblyAugmentorIncludesSubdirectoryInstructionsForNestedWorkingDirectory() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let module = root.appendingPathComponent("Sources/App", isDirectory: true)
    try fileManager.createDirectory(at: module, withIntermediateDirectories: true)
    try "root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "module rules".write(to: root.appendingPathComponent("Sources/AGENTS.md"), atomically: true, encoding: .utf8)
    try "local notes".write(to: module.appendingPathComponent("AGENTS.local.md"), atomically: true, encoding: .utf8)

    let augmentor = InstructionAssemblyPromptAugmentor()
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
            sessionID: "session-3",
            basePrompt: "Base system prompt",
            userPrompt: "hello",
            metadata: [
                PromptInstructionMetadataKeys.projectRootPath: .string(root.path),
                PromptInstructionMetadataKeys.workingDirectory: .string(module.path)
            ]
        )
    )

    let rendered = try #require(prompt)
    #expect(rendered.contains("Project instructions (AGENTS.md):\nroot rules"))
    #expect(rendered.contains("Subdirectory instructions (Sources/AGENTS.md):\nmodule rules"))
    #expect(rendered.contains("Local instructions (Sources/App/AGENTS.local.md):\nlocal notes"))
}

@Test
func instructionAssemblyAugmentorKeepsDistinctInstructionPathsWhenContentMatches() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let module = root.appendingPathComponent("Sources/App", isDirectory: true)
    try fileManager.createDirectory(at: module, withIntermediateDirectories: true)
    try "same rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "same rules".write(to: root.appendingPathComponent("Sources/AGENTS.md"), atomically: true, encoding: .utf8)

    let augmentor = InstructionAssemblyPromptAugmentor()
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
            sessionID: "session-4",
            userPrompt: "hello",
            metadata: [
                PromptInstructionMetadataKeys.projectRootPath: .string(root.path),
                PromptInstructionMetadataKeys.workingDirectory: .string(module.path)
            ]
        )
    )

    let rendered = try #require(prompt)
    #expect(rendered.contains("Project instructions (AGENTS.md):\nsame rules"))
    #expect(rendered.contains("Subdirectory instructions (Sources/AGENTS.md):\nsame rules"))
}

@Test
func instructionAssemblyAugmentorReplaceParentMergeModeDropsNearestInheritedDocument() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let module = root.appendingPathComponent("Sources/App", isDirectory: true)
    try fileManager.createDirectory(at: module, withIntermediateDirectories: true)
    try """
    ---
    native-agent-merge: append
    ---
    root rules
    """.write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try """
    ---
    native-agent-merge: replace-parent
    ---
    module rules
    """.write(to: root.appendingPathComponent("Sources/AGENTS.md"), atomically: true, encoding: .utf8)

    let augmentor = InstructionAssemblyPromptAugmentor()
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
            sessionID: "session-override-1",
            userPrompt: "hello",
            metadata: [
                PromptInstructionMetadataKeys.projectRootPath: .string(root.path),
                PromptInstructionMetadataKeys.workingDirectory: .string(module.path)
            ]
        )
    )

    let rendered = try #require(prompt)
    #expect(rendered.contains("module rules"))
    #expect(rendered.contains("root rules") == false)
}

@Test
func instructionAssemblyAugmentorReplaceProjectChainMergeModeDropsAllInheritedProjectDocuments() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let feature = root.appendingPathComponent("Sources/App/Feature", isDirectory: true)
    try fileManager.createDirectory(at: feature, withIntermediateDirectories: true)
    try "root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "module rules".write(to: root.appendingPathComponent("Sources/AGENTS.md"), atomically: true, encoding: .utf8)
    try """
    ---
    native-agent-merge: replace-project-chain
    ---
    feature rules
    """.write(to: root.appendingPathComponent("Sources/App/AGENTS.md"), atomically: true, encoding: .utf8)

    let augmentor = InstructionAssemblyPromptAugmentor()
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(
            sessionID: "session-override-2",
            userPrompt: "hello",
            metadata: [
                PromptInstructionMetadataKeys.projectRootPath: .string(root.path),
                PromptInstructionMetadataKeys.workingDirectory: .string(feature.path)
            ]
        )
    )

    let rendered = try #require(prompt)
    #expect(rendered.contains("feature rules"))
    #expect(rendered.contains("root rules") == false)
    #expect(rendered.contains("module rules") == false)
}

private enum PromptInstructionFileFixtureError: Error, Equatable {
    case unreadable
}

@Test
func instructionAssemblyAugmentorPropagatesInstructionReadFailure() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let augmentor = InstructionAssemblyPromptAugmentor(
        fileAccess: PromptInstructionFileAccess { url in
            if url.lastPathComponent == "AGENTS.md" {
                throw PromptInstructionFileFixtureError.unreadable
            }
            return nil
        },
        configuration: .makiLike
    )

    await #expect(throws: PromptInstructionFileFixtureError.unreadable) {
        try await augmentor.augmentSystemPrompt(
            PromptAugmentationRequest(
                sessionID: "instruction-read-failure",
                userPrompt: "hello",
                metadata: [
                    PromptInstructionMetadataKeys.workingDirectory: .string(root.path)
                ]
            )
        )
    }
}
