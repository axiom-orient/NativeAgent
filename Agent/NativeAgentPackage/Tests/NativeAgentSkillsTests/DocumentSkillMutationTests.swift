import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

private func documentSkill(
    name: String = "custom-skill",
    kind: ManagedSkillSource.Kind = .imported,
    location: String = "custom-skill",
    selected: Bool = true
) -> ManagedSkill {
    ManagedSkill(
        name: name,
        description: "Description",
        instructions: "Instructions",
        builtIn: false,
        selected: selected,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: kind == .web ? "web" : "custom",
        relativePath: "documents/\(location)/SKILL.md",
        excerpt: "Instructions",
        source: ManagedSkillSource(kind: kind, location: location),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
}

@Test
func documentSkillMutationReducerProducesAtomicInstallPlan() throws {
    let state = SkillState(
        updatedAt: Date(timeIntervalSince1970: 1),
        selectionOverrides: ["unrelated": false],
        remoteSkills: [documentSkill(name: "old-web", kind: .web, location: "old-web")]
    )
    let skill = documentSkill(selected: false)
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("custom-skill", isDirectory: true)
    let updatedAt = Date(timeIntervalSince1970: 2)

    let plan = try SkillDocumentMutationReducer().reduce(
        state: state,
        action: .install(
            SkillDocumentInstallRequest(
                skill: skill,
                sourceDirectory: source,
                directoryName: "custom-skill",
                replaceExistingImportedSkill: false,
                existingSkills: [],
                updatedAt: updatedAt
            )
        )
    )

    #expect(state.selectionOverrides == ["unrelated": false])
    #expect(plan.previousState == state)
    #expect(plan.updatedState.selectionOverrides == ["unrelated": false, "custom-skill": false])
    #expect(plan.updatedState.remoteSkills == state.remoteSkills)
    #expect(plan.updatedState.updatedAt == updatedAt)
    #expect(
        plan.directoryMutations == [
            SkillDirectoryMutation(
                directoryName: "custom-skill",
                contents: .copied(from: source)
            )
        ]
    )
}

@Test
func documentSkillMutationReducerReplacesOnlyImportedSkills() throws {
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("custom-skill", isDirectory: true)
    let request = SkillDocumentInstallRequest(
        skill: documentSkill(),
        sourceDirectory: source,
        directoryName: "custom-skill",
        replaceExistingImportedSkill: true,
        existingSkills: [documentSkill(kind: .web)],
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    #expect(throws: AgentError.self) {
        _ = try SkillDocumentMutationReducer().reduce(
            state: SkillState(),
            action: .install(request)
        )
    }
}

@Test
func documentSkillMutationReducerRemovesStateAndDirectoryTogether() throws {
    let skill = documentSkill(kind: .web)
    let state = SkillState(
        updatedAt: Date(timeIntervalSince1970: 1),
        selectionOverrides: [skill.name: true, "unrelated": false],
        remoteSkills: [skill]
    )

    let plan = try SkillDocumentMutationReducer().reduce(
        state: state,
        action: .remove(
            requestedName: skill.name,
            resolvedSkill: skill,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    )

    #expect(plan.updatedState.selectionOverrides == ["unrelated": false])
    #expect(plan.updatedState.remoteSkills.isEmpty)
    #expect(
        plan.directoryMutations == [
            SkillDirectoryMutation(directoryName: skill.source.location, contents: .absent)
        ]
    )
}

private actor DocumentSkillStatePersistenceFixture {
    enum FixtureError: Error {
        case saveRejected
    }

    private var state: SkillState
    private var rejectSave: Bool

    init(
        state: SkillState = SkillState(updatedAt: Date(timeIntervalSince1970: 1)),
        rejectSave: Bool = false
    ) {
        self.state = state
        self.rejectSave = rejectSave
    }

    nonisolated func boundary() -> SkillStatePersistenceBoundary {
        SkillStatePersistenceBoundary(
            prepare: {},
            load: { await self.currentState() },
            save: { state in try await self.save(state) }
        )
    }

    func rejectFutureSaves() {
        rejectSave = true
    }

    func currentState() -> SkillState {
        state
    }

    private func save(_ state: SkillState) throws {
        guard !rejectSave else { throw FixtureError.saveRejected }
        self.state = state
    }
}

private struct DocumentSkillRemoteFetcher: RemoteSkillFetcher {
    let package: RemoteSkillPackage

    func fetchSkillMarkdown(baseURL: URL) async throws -> String {
        guard let markdown = package.skillMarkdown else {
            throw AgentError.notFound("SKILL.md")
        }
        return markdown
    }

    func fetchSkillPackage(baseURL: URL) async throws -> RemoteSkillPackage {
        package
    }
}

private actor RejectingDeleteSecretStore: SkillSecretStore {
    enum FixtureError: Error {
        case deleteRejected
    }

    func readSecret(for skillName: String) async throws -> String? { nil }
    func writeSecret(_ value: String, for skillName: String) async throws {}
    func deleteSecret(for skillName: String) async throws { throw FixtureError.deleteRejected }
    func hasSecret(for skillName: String) async throws -> Bool { false }
}

private func documentWorkspace(root: URL) -> SkillWorkspace {
    SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
}

private func documentSkillMarkdown(name: String, instructions: String) -> String {
    """
    ---
    name: \(name)
    description: Test document skill
    ---

    \(instructions)
    """
}

@Test
func addCustomSkillRollsBackDirectoryWhenStateSaveFails() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = documentWorkspace(root: root)
    let persistence = DocumentSkillStatePersistenceFixture(rejectSave: true)
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )

    await #expect(throws: DocumentSkillStatePersistenceFixture.FixtureError.self) {
        _ = try await library.addCustomTextSkill(
            name: "atomic-add",
            description: "Atomic",
            instructions: "Keep state and files together",
            requiresSecret: false,
            requiresSecretDescription: "",
            homepage: ""
        )
    }

    #expect(!fileManager.fileExists(
        atPath: workspace.userSkillDirectoryURL(named: "atomic-add").path
    ))
    #expect(!fileManager.fileExists(
        atPath: workspace.userSkillsRootURL.appendingPathComponent(
            ".native-agent-skill-transaction",
            isDirectory: true
        ).path
    ))
    #expect(await persistence.currentState().selectionOverrides.isEmpty)
}

@Test
func upsertCustomSkillRestoresPreviousDirectoryWhenStateSaveFails() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = documentWorkspace(root: root)
    let directory = workspace.userSkillDirectoryURL(named: "atomic-upsert")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let originalMarkdown = documentSkillMarkdown(
        name: "atomic-upsert",
        instructions: "Original instructions"
    )
    try originalMarkdown.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let originalState = SkillState(
        updatedAt: Date(timeIntervalSince1970: 1),
        selectionOverrides: ["atomic-upsert": true]
    )
    let persistence = DocumentSkillStatePersistenceFixture(
        state: originalState,
        rejectSave: true
    )
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )

    await #expect(throws: DocumentSkillStatePersistenceFixture.FixtureError.self) {
        _ = try await library.upsertCustomTextSkill(
            name: "atomic-upsert",
            description: "Updated",
            instructions: "Replacement instructions",
            requiresSecret: false,
            requiresSecretDescription: "",
            homepage: ""
        )
    }

    let restoredMarkdown = try String(
        contentsOf: directory.appendingPathComponent("SKILL.md"),
        encoding: .utf8
    )
    #expect(restoredMarkdown == originalMarkdown)
    #expect(await persistence.currentState() == originalState)
}

@Test
func remoteSkillImportRollsBackPackageAndRemoteStateWhenSaveFails() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = documentWorkspace(root: root)
    let persistence = DocumentSkillStatePersistenceFixture(rejectSave: true)
    let markdown = documentSkillMarkdown(
        name: "atomic-web",
        instructions: "Read references/guide.md"
    )
    let fetcher = DocumentSkillRemoteFetcher(
        package: RemoteSkillPackage(files: [
            RemoteSkillPackageFile(relativePath: "SKILL.md", data: Data(markdown.utf8)),
            RemoteSkillPackageFile(
                relativePath: "references/guide.md",
                data: Data("guide".utf8)
            ),
        ])
    )
    let library = SkillLibrary(
        workspace: workspace,
        remoteFetcher: fetcher,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )

    await #expect(throws: DocumentSkillStatePersistenceFixture.FixtureError.self) {
        _ = try await library.importSkill(
            fromRemoteBaseURL: "https://example.com/skills/atomic-web"
        )
    }

    #expect(!fileManager.fileExists(
        atPath: workspace.userSkillDirectoryURL(named: "atomic-web").path
    ))
    #expect(await persistence.currentState().remoteSkills.isEmpty)
}

@Test
func removeCustomSkillRestoresDirectoryWhenStateSaveFails() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = documentWorkspace(root: root)
    let directory = workspace.userSkillDirectoryURL(named: "atomic-remove")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let markdown = documentSkillMarkdown(
        name: "atomic-remove",
        instructions: "Must survive rollback"
    )
    try markdown.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let originalState = SkillState(
        updatedAt: Date(timeIntervalSince1970: 1),
        selectionOverrides: ["atomic-remove": true]
    )
    let persistence = DocumentSkillStatePersistenceFixture(
        state: originalState,
        rejectSave: true
    )
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )

    await #expect(throws: DocumentSkillStatePersistenceFixture.FixtureError.self) {
        try await library.removeCustomSkill(named: "atomic-remove")
    }

    #expect(fileManager.fileExists(atPath: directory.path))
    #expect(
        try String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
            == markdown
    )
    #expect(await persistence.currentState() == originalState)
}

@Test
func removeCustomSkillReportsSecretFailureAsPostCommit() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = documentWorkspace(root: root)
    let persistence = DocumentSkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        secretStore: RejectingDeleteSecretStore(),
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    let skill = try await library.addCustomTextSkill(
        name: "post-commit-secret",
        description: "Secret failure",
        instructions: "Remove me",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: ""
    )

    await #expect(throws: SkillDocumentPostCommitFailure.self) {
        try await library.removeCustomSkill(named: skill.name)
    }

    #expect(!fileManager.fileExists(
        atPath: workspace.userSkillDirectoryURL(named: skill.source.location).path
    ))
    #expect(await persistence.currentState().selectionOverrides[skill.name] == nil)
}

private actor BlockingDocumentSkillStatePersistenceFixture {
    private var state = SkillState(updatedAt: Date(timeIntervalSince1970: 1))
    private var saveCount = 0
    private var firstSaveStarted = false
    private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveRelease: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    nonisolated func boundary() -> SkillStatePersistenceBoundary {
        SkillStatePersistenceBoundary(
            prepare: {},
            load: { await self.state },
            save: { state in await self.save(state) }
        )
    }

    func waitForFirstSave() async {
        if firstSaveStarted { return }
        await withCheckedContinuation { continuation in
            firstSaveWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        if let firstSaveRelease {
            self.firstSaveRelease = nil
            firstSaveRelease.resume()
        } else {
            releaseRequested = true
        }
    }

    func currentState() -> SkillState { state }

    private func save(_ newState: SkillState) async {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted = true
            let waiters = firstSaveWaiters
            firstSaveWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if releaseRequested {
                releaseRequested = false
            } else {
                await withCheckedContinuation { continuation in
                    firstSaveRelease = continuation
                }
            }
        }
        state = newState
    }
}

@Test
func customSkillMutationSerializesWithSelectionMutation() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = documentWorkspace(root: root)
    let persistence = BlockingDocumentSkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()

    let customMutation = Task {
        try await library.addCustomTextSkill(
            name: "serialized-custom",
            description: "Serialized",
            instructions: "Commit before the next state mutation",
            requiresSecret: false,
            requiresSecretDescription: "",
            homepage: ""
        )
    }
    await persistence.waitForFirstSave()

    let selectionMutation = Task {
        try await library.setSelected(skillName: "independent-selection", selected: true)
    }
    var queued = false
    for _ in 0..<1_000 {
        if case .active(let owner, let waiting) = await library.accessState,
              owner.kind == .customSkillMutation,
              waiting.first?.kind == .selectionMutation {
            queued = true
            break
        }
        await Task.yield()
    }
    #expect(queued)

    await persistence.releaseFirstSave()
    let skill = try await customMutation.value
    try await selectionMutation.value

    let state = await persistence.currentState()
    #expect(state.selectionOverrides[skill.name] == true)
    #expect(state.selectionOverrides["independent-selection"] == true)
    #expect(fileManager.fileExists(
        atPath: workspace.userSkillDirectoryURL(named: skill.source.location).path
    ))
}
