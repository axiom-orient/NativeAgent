import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

@Test
func skillExecutionSnapshotOwnsOneLibraryReadClaimAcrossCapture() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillExecutionSnapshot-access-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let skillRoot = workspace.userSkillDirectoryURL(named: "capture-skill")
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    try Data("""
        ---
        name: capture-skill
        description: Capture under one read claim
        ---

        Keep the selected metadata and files in one capture boundary.
        """.utf8).write(
        to: skillRoot.appendingPathComponent("SKILL.md", isDirectory: false),
        options: .atomic
    )

    let persistence = BlockingSnapshotLoadPersistence()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()

    let capture = Task {
        try await SkillExecutionSnapshot.capture(library: library)
    }
    await persistence.waitForBlockedLoad()

    let mutation = Task {
        try await library.setSelected(skillName: "capture-skill", selected: false)
    }

    var queuedBehindRead = false
    for _ in 0..<1_000 {
        if case .active(let owner, let waiting) = await library.accessState,
           owner.kind == .read,
           waiting.first?.kind == .selectionMutation {
            queuedBehindRead = true
            break
        }
        await Task.yield()
    }
    #expect(queuedBehindRead)

    await persistence.releaseBlockedLoad()
    let snapshot = try await capture.value
    try await mutation.value

    #expect(snapshot.selectedSkill(named: "capture-skill") != nil)
    #expect(try await library.selectedSkills().isEmpty)
}

@Test
func localWebViewURLRemainsValidAfterExecutionSnapshotIsReleased() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillExecutionSnapshot-webview-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let library = SkillLibrary(workspace: workspace)
    let html = "<html><body>durable preview</body></html>"
    _ = try await library.addCustomTextSkill(
        name: "Durable Preview",
        description: "Keeps local execution assets alive after the operation",
        instructions: "Use run_js.",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: ["index.html": "<html></html>"],
        assets: ["preview/index.html": html]
    )

    var snapshot: SkillExecutionSnapshot? = try await SkillExecutionSnapshot.capture(library: library)
    let skill = try #require(snapshot?.selectedSkills.first)
    let firstDigest = try #require(snapshot?.digest)
    let webViewURL = try #require(snapshot).resolveWebViewURL(
        for: skill,
        urlString: "preview/index.html"
    )
    #expect(FileManager.default.fileExists(atPath: webViewURL.path))

    snapshot = nil

    #expect(FileManager.default.fileExists(atPath: webViewURL.path))
    #expect(try String(contentsOf: webViewURL, encoding: .utf8) == html)

    let recaptured = try await SkillExecutionSnapshot.capture(library: library)
    let recapturedSkill = try #require(recaptured.selectedSkills.first)
    let recapturedURL = try recaptured.resolveWebViewURL(
        for: recapturedSkill,
        urlString: "preview/index.html"
    )
    #expect(recaptured.digest == firstDigest)
    #expect(recapturedURL == webViewURL)
}

@Test
func skillExecutionSnapshotRejectsTamperedContentAddressedCache() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillExecutionSnapshot-cache-integrity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    _ = try await library.addCustomTextSkill(
        name: "Cache Integrity",
        description: "Verifies immutable cached Skill bytes",
        instructions: "Use the captured asset.",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        scripts: [:],
        assets: ["preview/index.html": "<html>original</html>"]
    )

    let snapshot = try await SkillExecutionSnapshot.capture(library: library)
    let skill = try #require(snapshot.selectedSkills.first)
    let assetURL = try snapshot.resolveWebViewURL(for: skill, urlString: "preview/index.html")
    try "<html>tampered</html>".write(to: assetURL, atomically: true, encoding: .utf8)

    await #expect(throws: AgentError.self) {
        _ = try await SkillExecutionSnapshot.capture(library: library)
    }
}

@Test
func skillExecutionSnapshotDerivesMetadataFromCapturedBytesNotPreCaptureMetadata() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillExecutionSnapshot-metadata-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
    let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    try Data("""
        ---
        name: capture-skill
        description: NEW-CAPTURED-DESCRIPTION
        ---

        NEW-CAPTURED-INSTRUCTIONS
        """.utf8).write(
        to: sourceRoot.appendingPathComponent("SKILL.md", isDirectory: false),
        options: .atomic
    )

    let staleMetadata = ManagedSkill(
        name: "capture-skill",
        description: "OLD-PRECAPTURE-DESCRIPTION",
        instructions: "OLD-PRECAPTURE-INSTRUCTIONS",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "custom",
        relativePath: "custom/capture-skill",
        excerpt: "OLD-PRECAPTURE-INSTRUCTIONS",
        source: ManagedSkillSource(kind: .imported, location: "capture-skill")
    )

    let snapshot = try SkillExecutionSnapshot.captureSelectedSkills(
        [staleMetadata],
        sourceRoots: ["capture-skill": sourceRoot],
        cacheRoot: cacheRoot,
        fileManager: .default
    )
    let captured = try #require(snapshot.selectedSkill(named: "capture-skill"))

    #expect(captured.description == "NEW-CAPTURED-DESCRIPTION")
    #expect(captured.instructions == "NEW-CAPTURED-INSTRUCTIONS")
    #expect(captured.description != staleMetadata.description)
    #expect(captured.instructions != staleMetadata.instructions)
}

private actor BlockingSnapshotLoadPersistence {
    private var state = SkillState()
    private var shouldBlock = true
    private var loadStarted = false
    private var loadStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    nonisolated func boundary() -> SkillStatePersistenceBoundary {
        SkillStatePersistenceBoundary(
            prepare: {},
            load: { await self.load() },
            save: { state in await self.save(state) }
        )
    }

    func waitForBlockedLoad() async {
        if loadStarted { return }
        await withCheckedContinuation { continuation in
            loadStartedWaiters.append(continuation)
        }
    }

    func releaseBlockedLoad() {
        if let continuation = releaseContinuation {
            releaseContinuation = nil
            continuation.resume()
        } else {
            releaseRequested = true
        }
    }

    private func load() async -> SkillState {
        if shouldBlock {
            shouldBlock = false
            loadStarted = true
            let waiters = loadStartedWaiters
            loadStartedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if releaseRequested {
                releaseRequested = false
            } else {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }
        return state
    }

    private func save(_ newState: SkillState) {
        state = newState
    }
}
