import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func skillRuntimeResultBuilderProducesImageArtifactAndMetadata() throws {
    let builder = SkillRuntimeResultBuilder()
    let skill = ManagedSkill(
        name: "chart-maker",
        description: "Makes charts",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "featured",
        relativePath: "featured/chart-maker",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .bundled, location: "featured/chart-maker")
    )

    let result = try builder.scriptSuccessResult(
        skill: skill,
        scriptName: "main.js",
        response: SkillScriptResponse(
            result: "done",
            image: .init(base64: "data:image/png;base64,aGVsbG8=")
        ),
        resolvedWebViewURL: nil,
        callID: "call-1"
    )

    #expect(result.metadata["cardTitle"]?.stringValue == "Chart Maker")
    #expect(result.metadata["cardSubtitle"]?.stringValue == "Generated image")
    #expect(result.artifacts.count == 1)
    #expect(result.artifacts.first?.preferredFilename == "chart-maker-main.js.png")
}

@Test
func skillRuntimeRunJSReturnsMissingSecretWithoutInvokingRunner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let secretStore = RecordingSecretStore()
    let library = SkillLibrary(workspace: workspace, secretStore: secretStore)
    let runner = RecordingScriptRunner(response: SkillScriptResponse(result: "ok"))
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: runner,
        intentService: NoopIntentService()
    )

    _ = try await library.addCustomTextSkill(
        name: "Needs Secret",
        description: "Demo",
        instructions: "Use run_js",
        requiresSecret: true,
        requiresSecretDescription: "API key",
        homepage: "",
        scripts: ["index.html": "<html></html>"]
    )

    let result = try await runtime.runJS(
        skillName: "needs-secret",
        scriptName: "index.html",
        dataJSONString: "  ",
        callID: "call-secret",
        context: noopContext()
    )

    #expect(result.isError == true)
    #expect(result.metadata["missingSecret"]?.boolValue == true)
    #expect(result.metadata["skillName"]?.stringValue == "needs-secret")
    #expect((await runner.recordedInvocations()).isEmpty)
}
@Test
func skillToolPackCanonicalizesStructuredJSONArguments() async throws {
    let toolPack = SkillToolPack(runtime: FakeSkillRuntime())

    let runJSExecutor = try #require(toolPack.executors().first { $0.definition.name == "run_js" })
    let runJSResult = try await runJSExecutor.execute(
        call: ToolCall(
            id: "call-json",
            name: "run_js",
            arguments: [
                "skill_name": "charts",
                "script_name": "index.html",
                "data": [
                    "count": 2,
                    "nested": ["ok": true],
                ],
            ]
        ),
        context: noopContext()
    )

    #expect(
        runJSResult.renderedContent == "ran charts:index.html:{\"count\":2,\"nested\":{\"ok\":true}}")

    let runIntentExecutor = try #require(
        toolPack.executors().first { $0.definition.name == "run_intent" })
    let runIntentResult = try await runIntentExecutor.execute(
        call: ToolCall(
            id: "call-intent",
            name: "run_intent",
            arguments: [
                "intent": "drive.upload",
                "parameters": [
                    "path": "exports/report.html"
                ],
            ]
        ),
        context: noopContext()
    )

    #expect(runIntentResult.renderedContent.contains("drive.upload"))
    #expect(runIntentResult.renderedContent.contains("exports"))
    #expect(runIntentResult.renderedContent.contains("report.html"))
}

@Test
func skillRuntimeResultBuilderPersistsGenericArtifactsAndArtifactBackedWebView() throws {
    let builder = SkillRuntimeResultBuilder()
    let skill = ManagedSkill(
        name: "html-maker",
        description: "Makes html",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "featured",
        relativePath: "featured/html-maker",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .bundled, location: "featured/html-maker")
    )

    let result = try builder.scriptSuccessResult(
        skill: skill,
        scriptName: "index.html",
        response: SkillScriptResponse(
            result: "created",
            webview: .init(artifactFilename: "preview.html", title: "Preview"),
            artifacts: [
                .init(
                    filename: "preview.html",
                    mimeType: "text/html",
                    text: "<html><body>ok</body></html>",
                    role: .webview,
                    metadata: ["source": .string("generated")]
                ),
                .init(
                    filename: "data.json",
                    mimeType: "application/json",
                    text: "{\"ok\":true}",
                    role: .attachment
                ),
            ]
        ),
        resolvedWebViewURL: nil,
        callID: "call-artifacts"
    )

    #expect(result.output.objectValue?["cardKind"]?.stringValue == "skill.webview")
    #expect(result.output.objectValue?["webview"]?.objectValue?["kind"]?.stringValue == "artifact")
    #expect(
        result.output.objectValue?["webview"]?.objectValue?["artifactFilename"]?.stringValue
            == "preview.html")
    #expect(result.artifacts.count == 2)
    #expect(result.artifacts.first?.preferredFilename == "preview.html")
    #expect(result.artifacts.first?.metadata["preferredFilename"]?.stringValue == "preview.html")
    #expect(result.artifacts.first?.metadata["role"]?.stringValue == "webview")
}

@Test
func skillRuntimeResultBuilderRejectsAmbiguousArtifactContent() throws {
    let builder = SkillRuntimeResultBuilder()
    let skill = ManagedSkill(
        name: "ambiguous-artifact",
        description: "Produces an invalid artifact",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "featured",
        relativePath: "featured/ambiguous-artifact",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .bundled, location: "featured/ambiguous-artifact")
    )

    #expect(throws: AgentError.self) {
        try builder.scriptSuccessResult(
            skill: skill,
            scriptName: "index.js",
            response: SkillScriptResponse(
                artifacts: [
                    .init(
                        filename: "output.txt",
                        mimeType: "text/plain",
                        text: "plain text",
                        base64: "cGxhaW4gdGV4dA=="
                    )
                ]
            ),
            resolvedWebViewURL: nil,
            callID: "call-ambiguous-artifact"
        )
    }
}

@Test
func skillRuntimeResultBuilderRejectsInvalidImageBase64() throws {
    let builder = SkillRuntimeResultBuilder()
    let skill = ManagedSkill(
        name: "invalid-image",
        description: "Produces an invalid image",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "featured",
        relativePath: "featured/invalid-image",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .bundled, location: "featured/invalid-image")
    )

    #expect(throws: AgentError.self) {
        try builder.scriptSuccessResult(
            skill: skill,
            scriptName: "index.js",
            response: SkillScriptResponse(image: .init(base64: "not-base64!")),
            resolvedWebViewURL: nil,
            callID: "call-invalid-image"
        )
    }
}

@Test
func skillRuntimeRunJSResolvesImportedSkillWebViewURLBeforeBuildingResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let library = SkillLibrary(workspace: workspace)
    let runner = RecordingScriptRunner(
        response: SkillScriptResponse(
            result: "ok",
            webview: .init(url: "preview/index.html", title: "Preview")
        )
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: runner,
        intentService: NoopIntentService()
    )

    let skill = try await library.addCustomTextSkill(
        name: "HTML Skill",
        description: "Demo",
        instructions: "Use run_js",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: ["index.html": "<html></html>"],
        assets: ["preview/index.html": "<html><body>Preview</body></html>"]
    )
    let expectedWebViewURL = try await library.resolveWebViewURL(
        for: skill, urlString: "preview/index.html")

    let result = try await runtime.runJS(
        skillName: skill.name,
        scriptName: "index.html",
        dataJSONString: "",
        callID: "call-webview",
        context: noopContext()
    )
    let expectedReadAccessURL = try await library.skillDirectoryURL(for: skill)

    #expect(
        result.output.objectValue?["webview"]?.objectValue?["url"]?.stringValue
            == expectedWebViewURL.absoluteString
    )
    let invocation = try #require(await runner.recordedInvocations().first)
    #expect(invocation.skillName == skill.name)
    #expect(invocation.inputJSON == "{}")
    #expect(invocation.readAccessURL == expectedReadAccessURL)
}

@Test
func skillRuntimeRunJSSurfacesRunnerFailureAsToolError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let library = SkillLibrary(workspace: workspace)
    let runner = ThrowingScriptRunner(error: EffectFailure.definiteFailure(
        operation: "skill.run_js", cause: "blocked by host script policy"))
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: runner,
        intentService: NoopIntentService()
    )

    let skill = try await library.addCustomTextSkill(
        name: "HTML Skill",
        description: "Demo",
        instructions: "Use run_js",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: ["index.html": "<html></html>"]
    )

    let result = try await runtime.runJS(
        skillName: skill.name,
        scriptName: "index.html",
        dataJSONString: "{}",
        callID: "call-error",
        context: noopContext()
    )

    #expect(result.isError)
    #expect(result.toolName == "run_js")
    #expect(result.output.objectValue?["cardKind"]?.stringValue == "skill.error")
    #expect(result.output.objectValue?["content"]?.stringValue == "operation=skill.run_js; cause=blocked by host script policy")
    #expect(await runner.invocationCount == 1)
}


@Test
func skillRuntimeRunJSPreservesExplicitUnknownOutcomeForEffectReconciliation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let library = SkillLibrary(workspace: workspace)
    let runner = ThrowingScriptRunner(
        error: EffectFailure.outcomeUnknown(
            operation: "skill.run_js",
            cause: "transport closed after dispatch"
        )
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: runner,
        intentService: NoopIntentService()
    )

    let skill = try await library.addCustomTextSkill(
        name: "HTML Skill Unknown",
        description: "Demo",
        instructions: "Use run_js",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: ["index.html": "<html></html>"]
    )

    do {
        _ = try await runtime.runJS(
            skillName: skill.name,
            scriptName: "index.html",
            dataJSONString: "{}",
            callID: "call-unknown",
            context: noopContext()
        )
        Issue.record("run_js must rethrow an explicitly unknown external outcome")
    } catch let failure as EffectFailure {
        #expect(failure.effectFailureCertainty == .outcomeUnknown)
        #expect(failure.operation == "skill.run_js")
        #expect(failure.cause == "transport closed after dispatch")
    }
    #expect(await runner.invocationCount == 1)
}

@Test
func skillRuntimeRunJSPreservesUnclassifiedCancellationForEffectReconciliation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let library = SkillLibrary(workspace: workspace)
    let runner = ThrowingScriptRunner(
        error: CancellationError()
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: runner,
        intentService: NoopIntentService()
    )

    let skill = try await library.addCustomTextSkill(
        name: "HTML Skill Unknown",
        description: "Demo",
        instructions: "Use run_js",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: ["index.html": "<html></html>"]
    )

    do {
        _ = try await runtime.runJS(
            skillName: skill.name,
            scriptName: "index.html",
            dataJSONString: "{}",
            callID: "call-unknown",
            context: noopContext()
        )
        Issue.record("run_js must rethrow an explicitly unknown external outcome")
    } catch is CancellationError {
        // The original unclassified error reaches the journal unchanged.
    }
    #expect(await runner.invocationCount == 1)
}
