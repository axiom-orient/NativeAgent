import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test(arguments: [
    "requiresNetwork", "allowedDomains", "requiresPersistentStorage",
    "requiresCameraOrMicrophone", "requiresExternalNavigation", "bridgeIntents", "hostIntents"
])
func persistedSkillCapabilitiesRequireEveryDeclaredField(field: String) throws {
    let current = SkillCapabilityRequirements(requiresNetwork: true, allowedDomains: ["example.com"])
    let encoded = try JSONValue.encode(current)
    #expect(try encoded.decode(SkillCapabilityRequirements.self) == current)
    var object = try #require(encoded.objectValue)
    object.removeValue(forKey: field)
    #expect(throws: DecodingError.self) {
        try JSONValue.object(object).decode(SkillCapabilityRequirements.self)
    }
    object[field] = .null
    #expect(throws: DecodingError.self) {
        try JSONValue.object(object).decode(SkillCapabilityRequirements.self)
    }
}

@Test
func skillLibrarySelectionReducerUpdatesOverridesAndRemoteSkills() {
    let timestamp = Date(timeIntervalSince1970: 456)
    let reducer = SkillLibrarySelectionReducer(now: { timestamp })

    let remoteSkill = ManagedSkill(
        name: "remote-skill",
        description: "Remote",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "remote/remote-skill/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .remote, location: "https://example.com/remote-skill")
    )
    let customSkill = ManagedSkill(
        name: "custom-skill",
        description: "Custom",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "custom/custom-skill/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .imported, location: "custom/custom-skill")
    )
    let state = SkillState(remoteSkills: [remoteSkill])

    let single = reducer.setSelected(state: state, skillName: "built-in", selected: false)
    #expect(single.selectionOverrides["built-in"] == false)
    #expect(single.updatedAt == timestamp)

    let all = reducer.setAllSelected(
        state: state,
        skills: [
            remoteSkill,
            customSkill,
            ManagedSkill(
                name: "built-in",
                description: "Built in",
                instructions: "Use run_js",
                builtIn: true,
                selected: true,
                requiresSecret: false,
                requiresSecretDescription: "",
                homepage: "",
                group: "built-in",
                relativePath: "skills/built-in/built-in/SKILL.md",
                excerpt: "Use run_js",
                source: ManagedSkillSource(kind: .bundled, location: "skills/built-in/built-in")
            ),
        ],
        selected: false
    )

    #expect(all.remoteSkills.first?.selected == false)
    #expect(all.remoteSkills.first?.updatedAt == timestamp)
    #expect(all.selectionOverrides["custom-skill"] == false)
    #expect(all.selectionOverrides["built-in"] == false)
    #expect(all.updatedAt == timestamp)
}

@Test
func managedSkillEventsProduceIndependentSnapshots() {
    let initial = ManagedSkill(
        name: "immutable-skill",
        description: "Immutable state test",
        instructions: "Use run_intent and preserve state snapshots.",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "custom/immutable-skill/SKILL.md",
        excerpt: "initial excerpt",
        source: ManagedSkillSource(kind: .imported, location: "immutable-skill"),
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    let selected = initial.applying(.selectionChanged(false, updatedAt: Date(timeIntervalSince1970: 2)))
    let supported = selected.applying(.executionSupportChanged(
        .unavailableOnMobile,
        reason: "requires an unavailable runtime",
        updatedAt: Date(timeIntervalSince1970: 3)
    ))
    let grouped = supported.applying(.groupChanged("web")).applying(.excerptRefreshed)

    #expect(initial.selected)
    #expect(initial.executionSupport == .available)
    #expect(initial.group == "custom")
    #expect(initial.excerpt == "initial excerpt")
    #expect(selected.selected == false)
    #expect(selected.updatedAt == Date(timeIntervalSince1970: 2))
    #expect(supported.executionSupport == .unavailableOnMobile)
    #expect(supported.executionSupportReason == "requires an unavailable runtime")
    #expect(supported.updatedAt == Date(timeIntervalSince1970: 3))
    #expect(grouped.group == "web")
    #expect(grouped.excerpt == grouped.instructionsPreview())
}

@Test
func skillStateEventsReturnIndependentSnapshots() {
    let createdAt = Date(timeIntervalSince1970: 1)
    let updatedAt = Date(timeIntervalSince1970: 2)
    let original = SkillState(
        updatedAt: createdAt,
        selectionOverrides: ["original": true]
    )

    let updated = original.applying(
        .contentsChanged(
            selectionOverrides: ["replacement": false],
            remoteSkills: [],
            installedPlugins: [],
            updatedAt: updatedAt
        )
    )

    #expect(original.selectionOverrides == ["original": true])
    #expect(original.updatedAt == createdAt)
    #expect(updated.selectionOverrides == ["replacement": false])
    #expect(updated.updatedAt == updatedAt)
    #expect(updated.version == original.version)
}

@Test
func fileSkillSecretStoreRejectsOutputThatCannotBeReadBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("secrets.json")
    let store = FileSkillSecretStore(fileURL: fileURL)
    let oversized = String(
        repeating: "s",
        count: SkillLocalFileLimits.maximumStateBytes
    )

    await #expect(throws: AgentError.self) {
        try await store.writeSecret(oversized, for: "oversized")
    }
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
}

private struct InjectedSkillSecretReplaceFailure: Error {}

@Test
func fileSkillSecretStorePreservesPreviousDocumentWhenReplacementFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("secrets.json")
    let originalStore = FileSkillSecretStore(fileURL: fileURL)
    try await originalStore.writeSecret("original", for: "demo")

    let failingWriter = SkillSecretFileWriter { source, destination in
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        throw InjectedSkillSecretReplaceFailure()
    }
    let failingStore = FileSkillSecretStore(
        fileURL: fileURL,
        fileWriter: failingWriter
    )

    await #expect(throws: InjectedSkillSecretReplaceFailure.self) {
        try await failingStore.writeSecret("replacement", for: "demo")
    }

    #expect(try await originalStore.readSecret(for: "demo") == "original")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["secrets.json"])
}

@Test
func fileSkillSecretStoreWritesOwnerOnlyFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("secrets.json")
    let store = FileSkillSecretStore(fileURL: fileURL)

    try await store.writeSecret("secret", for: "demo")

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
    #expect(try await store.readSecret(for: "demo") == "secret")

    // A world-readable file left by an earlier build must not survive a rewrite,
    // and no temporary sibling may be published at a wider mode either.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fileURL.path
    )
    try await store.writeSecret("rotated", for: "demo")

    let rewritten = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let rewrittenPermissions = try #require(rewritten[.posixPermissions] as? NSNumber)
    #expect(rewrittenPermissions.intValue & 0o777 == 0o600)
    #expect(try await store.readSecret(for: "demo") == "rotated")

    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(siblings == ["secrets.json"])
}

@Test
func skillPathPolicyNormalizesAndValidatesSandboxedPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let policy = SkillPathPolicy(
        workspace: .init(
            supportRootURL: root,
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)))

    let remoteBase = try policy.normalizeRemoteSkillBaseURL(
        " https://example.com/skills/demo/SKILL.md ")
    #expect(remoteBase.absoluteString == "https://example.com/skills/demo")

    let localhostBase = try policy.normalizeRemoteSkillBaseURL("http://localhost:3000/skills/demo/")
    #expect(localhostBase.absoluteString == "http://localhost:3000/skills/demo")

    let loopbackBase = try policy.normalizeRemoteSkillBaseURL("http://127.0.0.1:8080/skills/demo")
    #expect(loopbackBase.absoluteString == "http://127.0.0.1:8080/skills/demo")

    let ipv6Base = try policy.normalizeRemoteSkillBaseURL("http://[::1]:8080/skills/demo")
    #expect(ipv6Base.absoluteString == "http://[::1]:8080/skills/demo")

    let sanitized = try policy.sanitizeRelativeSkillPath(" assets/chart.png ", kind: "asset")
    #expect(sanitized == "assets/chart.png")

    let child = try policy.validatedChildURL(named: "assets/chart.png", within: root)
    #expect(child.path.hasSuffix("/assets/chart.png"))

    #expect(throws: AgentError.self) {
        _ = try policy.remoteURL(
            baseURL: "https://example.com/skills/demo",
            pathComponent: "../other/SKILL.md"
        )
    }

    try policy.validateWorkspaceURL(root.appendingPathComponent("assets/chart.png"))
}

@Test
func skillPathPolicyRejectsTraversalAndSandboxEscape() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let policy = SkillPathPolicy(
        workspace: .init(
            supportRootURL: root,
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)))

    #expect(throws: AgentError.self) {
        _ = try policy.sanitizeRelativeSkillPath("../secret", kind: "asset")
    }

    #expect(throws: AgentError.self) {
        _ = try policy.normalizeRemoteSkillBaseURL("http://example.com/skills/demo")
    }

    #expect(throws: AgentError.self) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill", isDirectory: true)
        _ = try policy.normalizeRemoteSkillBaseURL(fileURL.absoluteString)
    }

    #expect(throws: AgentError.self) {
        _ = try policy.normalizeRemoteSkillBaseURL("javascript:alert(1)")
    }

    #expect(throws: AgentError.self) {
        try policy.validateWorkspaceURL(
            FileManager.default.temporaryDirectory.appendingPathComponent("outside")
        )
    }
}

@Test
func skillFileImportPolicyCopiesFilesAndRejectsSymlinks() throws {
    let fileManager = FileManager.default
    let sandboxRoot = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

    let source = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    try fileManager.createDirectory(
        at: source.appendingPathComponent("scripts", isDirectory: true),
        withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: source.appendingPathComponent("scripts/index.js"))

    let destination = sandboxRoot.appendingPathComponent("Documents/Skills/demo", isDirectory: true)
    let policy = SkillFileImportPolicy(
        fileManager: fileManager,
        pathPolicy: SkillPathPolicy(
            workspace: .init(
                supportRootURL: sandboxRoot,
                userSkillsRootURL: sandboxRoot.appendingPathComponent("Documents/Skills", isDirectory: true)
            )))

    try policy.createOrReplaceDirectory(destination)
    try policy.copySkillDirectory(from: source, to: destination)
    #expect(
        fileManager.fileExists(atPath: destination.appendingPathComponent("scripts/index.js").path))

    let linked = source.appendingPathComponent("linked", isDirectory: false)
    try? fileManager.removeItem(at: linked)
    try fileManager.createSymbolicLink(
        at: linked, withDestinationURL: source.appendingPathComponent("scripts/index.js"))

    #expect(throws: AgentError.self) {
        try policy.copySkillDirectory(from: source, to: destination)
    }
}

@Test
func skillSnapshotBuilderSortsCustomAndMergesSelectedFirst() {
    let builder = SkillLibrarySnapshotBuilder(groupOrder: { group in
        switch group {
        case "built-in": return 0
        case "featured": return 1
        case "custom": return 2
        default: return 3
        }
    })

    let builtIn = ManagedSkill(
        name: "a-built-in",
        description: "Built in",
        instructions: "Use run_js",
        builtIn: true,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "built-in",
        relativePath: "skills/built-in/a-built-in/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .bundled, location: "skills/built-in/a-built-in")
    )
    let customA = ManagedSkill(
        name: "z-custom",
        description: "Custom Z",
        instructions: "Use run_js",
        builtIn: false,
        selected: false,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "documents/z-custom/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .imported, location: "z-custom")
    )
    let customB = ManagedSkill(
        name: "a-custom",
        description: "Custom A",
        instructions: "Use run_js",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "documents/a-custom/SKILL.md",
        excerpt: "Use run_js",
        source: ManagedSkillSource(kind: .imported, location: "a-custom")
    )

    let sortedCustom = builder.sortCustomSkills([customA, customB])
    #expect(sortedCustom.map(\.name) == ["a-custom", "z-custom"])

    let merged = builder.mergeSkills(bundledSkills: [builtIn], customSkills: sortedCustom)
    #expect(merged.map(\.name) == ["a-built-in", "a-custom", "z-custom"])
}

@Test
func skillMarkdownFrontmatterParserSeparatesMetadataFromInstructions() throws {
    let markdown = """
        ---
        name: demo-skill
        description: Demo skill
        metadata:
          require-secret: true
          require-secret-description: API key
          homepage: https://example.com
        ---

        Use run_js
        """

    let parsed = try SkillMarkdownFrontmatterParser.parse(markdown)
    #expect(parsed.frontmatter.name == "demo-skill")
    #expect(parsed.frontmatter.description == "Demo skill")
    #expect(parsed.frontmatter.requiresSecret == true)
    #expect(parsed.frontmatter.requiresSecretDescription == "API key")
    #expect(parsed.frontmatter.homepage == "https://example.com")
    #expect(parsed.instructions == "Use run_js")
}

@Test
func skillMarkdownFrontmatterParserRejectsMissingName() {
    let markdown = """
        ---
        description: Demo skill
        ---

        Use run_js
        """

    #expect(throws: AgentError.self) {
        _ = try SkillMarkdownFrontmatterParser.parse(markdown)
    }
}

@Test
func fileSkillSecretStoreRejectsMissingOrUnsupportedV1Contract() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("secrets.json")
    let store = FileSkillSecretStore(fileURL: fileURL)

    try Data("{}".utf8).write(to: fileURL)
    await #expect(throws: (any Error).self) {
        _ = try await store.readSecret(for: "demo")
    }

    try Data(#"{"version":"native-agent.skill.secrets/99","secrets":{}}"#.utf8).write(to: fileURL)
    await #expect(throws: (any Error).self) {
        _ = try await store.readSecret(for: "demo")
    }
}

@Test
func bundledSkillsUseOneResourcePathWithoutFlattenedLookup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-bundle-" + UUID().uuidString)
    let bundleURL = root.appendingPathComponent("Skills.bundle")
    let resources = bundleURL.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info: [String: Any] = [
        "CFBundleIdentifier": "test.nativeagent.skills." + UUID().uuidString.lowercased(),
        "CFBundleName": "Skills", "CFBundlePackageType": "BNDL"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: bundleURL))
    let resourceRoot = try #require(bundle.resourceURL)
    let canonical = resourceRoot.appendingPathComponent("skills/built-in/bundled-test", isDirectory: true)
    let flattened = resourceRoot.appendingPathComponent("built-in/bundled-test")
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: flattened, withIntermediateDirectories: true)
    let markdown = """
    ---
    name: bundled-test
    description: Bundled path contract
    ---
    Use this exact bundled document.
    """
    try markdown.write(to: canonical.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try markdown.write(to: flattened.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("workspace"),
            userSkillsRootURL: root.appendingPathComponent("workspace/skills")
        ), bundle: bundle
    )
    let loaded = try await library.loadBundledSkills(selectionOverrides: [:])
    let skill = try #require(loaded.first)
    #expect(loaded.count == 1)
    #expect(try await library.skillDirectoryURL(for: skill) == canonical.standardizedFileURL)
    try FileManager.default.removeItem(at: resourceRoot.appendingPathComponent("skills"))
    #expect(try await library.loadBundledSkills(selectionOverrides: [:]).isEmpty)
    await #expect(throws: AgentError.self) {
        try await library.skillDirectoryURL(for: skill)
    }
}
