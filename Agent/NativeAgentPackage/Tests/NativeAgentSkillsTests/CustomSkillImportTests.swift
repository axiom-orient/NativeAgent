import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func addCustomTextSkillWritesScriptsAndAssets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)))

    let skill = try await library.addCustomTextSkill(
        name: "HTML Skill",
        description: "Demo",
        instructions: "Use run_js",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: [
            "index.html":
                "<script>window.nativeAgentRun = async () => '{\\\"result\\\":\\\"ok\\\"}';</script>",
            "helpers/init.js": "console.log('init');",
        ],
        assets: [
            "ui/view.html": "<html><body>View</body></html>"
        ],
        binaryAssets: [
            "images/icon.bin": Data([0x01, 0x02, 0x03])
        ]
    )

    let directory = try await library.skillDirectoryURL(for: skill)
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("scripts/index.html").path))
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("scripts/helpers/init.js").path))
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("assets/ui/view.html").path))
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("assets/images/icon.bin").path))
}

@Test
func addCustomTextSkillRejectsTraversalEntries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)))

    await #expect(throws: AgentError.self) {
        _ = try await library.addCustomTextSkill(
            name: "bad-skill",
            description: "Demo",
            instructions: "Use run_js",
            requiresSecret: false,
            requiresSecretDescription: "",
            homepage: "",
            scripts: ["../escape.js": "boom"]
        )
    }
}

@Test
func importSkillRejectsInsecureRemoteBaseURL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        ),
        remoteFetcher: StaticRemoteSkillFetcher(
            markdown: """
                ---
                name: remote-demo
                description: Demo
                ---

                Use run_js
                """)
    )

    await #expect(throws: AgentError.self) {
        _ = try await library.importSkill(fromRemoteBaseURL: "http://example.com/skills/demo")
    }
}

@Test
func importRemoteSkillInstallsCompletePackageAndMarksScriptsUnavailableOnIOS() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let markdown = """
        ---
        name: web-tool-skill
        description: Web skill with references and scripts
        ---

        Use run_js with scripts/index.js after reading references/guide.md.
        """
    let package = RemoteSkillPackage(files: [
        RemoteSkillPackageFile(relativePath: "SKILL.md", data: Data(markdown.utf8)),
        RemoteSkillPackageFile(relativePath: "references/guide.md", data: Data("reference".utf8)),
        RemoteSkillPackageFile(relativePath: "eval/case.md", data: Data("eval".utf8)),
        RemoteSkillPackageFile(
            relativePath: "scripts/index.js", data: Data("export default {}".utf8)),
    ])
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        ),
        remoteFetcher: StaticRemoteSkillFetcher(markdown: markdown, package: package)
    )
    let runner = RecordingScriptRunner(response: SkillScriptResponse(result: "should not run"))
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: runner,
        intentService: NoopIntentService()
    )

    let imported = try await library.importSkill(
        fromRemoteBaseURL: "https://example.com/skills/web-tool-skill")
    let snapshot = try await library.snapshot()
    let skill = try #require(snapshot.skills.first { $0.name == "web-tool-skill" })
    let skillDirectory = try await library.skillDirectoryURL(for: skill)
    let prompt = SkillSystemPromptBuilder().build(
        basePrompt: "Base", selectedSkills: snapshot.skills)
    let runResult = try await runtime.runJS(
        skillName: skill.name,
        scriptName: "index.js",
        dataJSONString: "{}",
        callID: "call-web-tool",
        context: noopContext()
    )

    #expect(imported.source.kind == .web)
    #expect(skill.source.kind == .web)
    #expect(skill.group == "web")
    #expect(skill.executionSupport == .unavailableOnMobile)
    #expect(skill.isExecutionAvailable == false)
    #expect(
        FileManager.default.fileExists(
            atPath: skillDirectory.appendingPathComponent("references/guide.md").path))
    #expect(
        FileManager.default.fileExists(
            atPath: skillDirectory.appendingPathComponent("eval/case.md").path))
    #expect(
        FileManager.default.fileExists(
            atPath: skillDirectory.appendingPathComponent("scripts/index.js").path))
    #expect(prompt.contains("execution unavailable on iOS"))
    #expect(runResult.toolName == "run_js")
    #expect(runResult.isError)
    #expect(
        runResult.renderedContent.contains("script or external-tool execution is unavailable on iOS"))
    #expect(runResult.metadata["executionSupport"]?.stringValue == "unavailableOnMobile")
    #expect(runResult.metadata["errorCode"]?.stringValue == ToolFailureCode.unsupported.rawValue)
    #expect((await runner.recordedInvocations()).isEmpty)
}

@Test
func importRemoteSkillInstallsDocumentationOnlyPackageAsExecutableAvailable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let markdown = """
        ---
        name: web-doc-skill
        description: Web documentation skill
        ---

        Read references/usage.md and answer with the documented checklist.
        """
    let package = RemoteSkillPackage(files: [
        RemoteSkillPackageFile(relativePath: "SKILL.md", data: Data(markdown.utf8)),
        RemoteSkillPackageFile(relativePath: "references/usage.md", data: Data("usage".utf8)),
        RemoteSkillPackageFile(relativePath: "eval/checklist.md", data: Data("check".utf8)),
    ])
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        ),
        remoteFetcher: StaticRemoteSkillFetcher(markdown: markdown, package: package)
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: RecordingScriptRunner(response: SkillScriptResponse(result: "")),
        intentService: NoopIntentService()
    )

    let imported = try await library.importSkill(
        fromRemoteBaseURL: "https://example.com/skills/web-doc-skill")
    let skillDirectory = try await library.skillDirectoryURL(for: imported)
    let snapshotSkill = try #require(
        (try await library.snapshot()).skills.first { $0.name == imported.name })
    let loaded = try await runtime.loadSkill(named: snapshotSkill.name, callID: "load-web-doc")
    let supportingFiles = try #require(loaded.output.objectValue?["supportingFiles"]?.arrayValue)

    #expect(snapshotSkill.source.kind == .web)
    #expect(snapshotSkill.executionSupport == .available)
    #expect(snapshotSkill.isExecutionAvailable)
    #expect(
        FileManager.default.fileExists(
            atPath: skillDirectory.appendingPathComponent("references/usage.md").path))
    #expect(
        FileManager.default.fileExists(
            atPath: skillDirectory.appendingPathComponent("eval/checklist.md").path))
    #expect(
        supportingFiles.contains { file in
            file.objectValue?["relativePath"]?.stringValue == "references/usage.md"
                && file.objectValue?["preview"]?.stringValue == "usage"
        })
    #expect(
        supportingFiles.contains { file in
            file.objectValue?["relativePath"]?.stringValue == "eval/checklist.md"
                && file.objectValue?["preview"]?.stringValue == "check"
        })
    #expect(loaded.renderedContent.contains("## Installed Supporting Files"))
    #expect(loaded.renderedContent.contains("references/usage.md"))
}

@Test
func remoteSkillResolutionUsesTrustedURLPolicy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )

    let secureSkill = ManagedSkill(
        name: "remote-secure",
        description: "Remote",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "https://example.com/skills/demo/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .remote, location: "https://example.com/skills/demo")
    )
    let localhostSkill = ManagedSkill(
        name: "remote-localhost",
        description: "Remote",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "http://localhost:3000/skills/demo/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .remote, location: "http://localhost:3000/skills/demo")
    )
    let insecureSkill = ManagedSkill(
        name: "remote-insecure",
        description: "Remote",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "http://example.com/skills/demo/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .remote, location: "http://example.com/skills/demo")
    )

    let scriptURL = try await library.resolveScriptURL(for: secureSkill, scriptName: "index.html")
    #expect(scriptURL.absoluteString == "https://example.com/skills/demo/scripts/index.html")

    let assetURL = try await library.resolveWebViewURL(
        for: localhostSkill, urlString: "preview/index.html")
    #expect(assetURL.absoluteString == "http://localhost:3000/skills/demo/assets/preview/index.html")

    let httpsWebView = try await library.resolveWebViewURL(
        for: secureSkill, urlString: "https://example.com/preview")
    #expect(httpsWebView.absoluteString == "https://example.com/preview")

    let localhostWebView = try await library.resolveWebViewURL(
        for: secureSkill, urlString: "http://127.0.0.1:8080/preview")
    #expect(localhostWebView.absoluteString == "http://127.0.0.1:8080/preview")

    let aboutWebView = try await library.resolveWebViewURL(for: secureSkill, urlString: "about:blank")
    #expect(aboutWebView.absoluteString == "about:blank")

    let dataWebView = try await library.resolveWebViewURL(
        for: secureSkill,
        urlString: "data:text/html,%3Chtml%3Eok%3C/html%3E"
    )
    #expect(dataWebView.absoluteString == "data:text/html,%3Chtml%3Eok%3C/html%3E")

    await #expect(throws: AgentError.self) {
        _ = try await library.resolveScriptURL(for: insecureSkill, scriptName: "index.html")
    }

    await #expect(throws: AgentError.self) {
        _ = try await library.resolveWebViewURL(for: insecureSkill, urlString: "preview/index.html")
    }

    await #expect(throws: AgentError.self) {
        _ = try await library.resolveWebViewURL(
            for: secureSkill, urlString: "http://example.com/preview")
    }

    await #expect(throws: AgentError.self) {
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview.html")
        _ = try await library.resolveWebViewURL(
            for: secureSkill,
            urlString: outsideURL.absoluteString
        )
    }

    await #expect(throws: AgentError.self) {
        _ = try await library.resolveWebViewURL(for: secureSkill, urlString: "javascript:alert(1)")
    }
}
