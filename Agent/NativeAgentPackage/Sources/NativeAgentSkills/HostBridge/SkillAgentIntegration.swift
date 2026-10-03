import NativeAgentDomain

/// Coherent Agent capability for the managed skill subsystem.
///
/// The capability contributes the three skill tools and the catalog prompt
/// augmentation as one unit. The host still owns concrete script and native
/// intent adapters; NativeAgent never fabricates an execution surface.
public struct SkillAgentIntegration: AgentCapability {
    private let toolPack: SkillToolPack
    private let promptAugmentor: SkillsPromptAugmentor

    public init(
        promptSource: any SkillPromptSource,
        runtime: any SkillRuntimeClient
    ) {
        self.toolPack = SkillToolPack(runtime: runtime)
        self.promptAugmentor = SkillsPromptAugmentor(source: promptSource)
    }

    public init(
        library: SkillLibrary,
        runtime: any SkillRuntimeClient
    ) {
        self.init(promptSource: library, runtime: runtime)
    }

    public init(
        library: SkillLibrary,
        scriptRunner: any SkillScriptRunner,
        intentService: any SkillIntentService
    ) {
        self.init(
            library: library,
            runtime: SkillRuntime(
                library: library,
                scriptRunner: scriptRunner,
                intentService: intentService
            )
        )
    }


    package init(
        snapshot: SkillExecutionSnapshot,
        secretLibrary: SkillLibrary,
        scriptRunner: any SkillScriptRunner,
        intentService: any SkillIntentService
    ) {
        let runtime = SkillRuntime(
            selectedSkillsLoader: { snapshot.selectedSkills },
            selectedSkillLoader: { name in snapshot.selectedSkill(named: name) },
            supportingFileLoader: { skill in try snapshot.supportingFiles(for: skill) },
            supportingFileReader: { skill, path, offset, limit in
                try snapshot.readSupportingFile(
                    for: skill,
                    relativePath: path,
                    characterOffset: offset,
                    maxCharacters: limit
                )
            },
            scriptURLResolver: { skill, scriptName in
                try snapshot.resolveScriptURL(for: skill, scriptName: scriptName)
            },
            readAccessURLResolver: { skill in try snapshot.readAccessURL(for: skill) },
            webViewURLResolver: { skill, urlString in
                try snapshot.resolveWebViewURL(for: skill, urlString: urlString)
            },
            secretReader: { skillName in try await secretLibrary.readSecret(for: skillName) },
            scriptRunner: scriptRunner,
            intentService: intentService
        )
        self.init(promptSource: snapshot, runtime: runtime)
    }

    public var packID: String { toolPack.packID }

    public func executors() -> [any ToolExecutor] {
        toolPack.executors()
    }

    public func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
        try await promptAugmentor.augmentSystemPrompt(request)
    }

}
