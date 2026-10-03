import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func skillLibraryAccessReducerGrantsClaimsInFIFOOrder() throws {
    let first = SkillLibraryAccessClaim(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
        kind: .selectionMutation
    )
    let second = SkillLibraryAccessClaim(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
        kind: .read
    )
    let reducer = SkillLibraryAccessReducer()

    let started = try reducer.reduce(state: .idle, action: .request(first))
    #expect(started.state == .active(owner: first, waiting: []))
    #expect(started.effects == [.grant(first)])

    let queued = try reducer.reduce(state: started.state, action: .request(second))
    #expect(queued.state == .active(owner: first, waiting: [second]))
    #expect(queued.effects == [.suspend(second)])

    let released = try reducer.reduce(state: queued.state, action: .release(first.id))
    #expect(released.state == .active(owner: second, waiting: []))
    #expect(released.effects == [.grant(second)])

    let idle = try reducer.reduce(state: released.state, action: .release(second.id))
    #expect(idle.state == .idle)
    #expect(idle.effects.isEmpty)
}

@Test
func skillLibraryAccessReducerCancellationReleasesAnUndeliveredOwner() throws {
    let first = SkillLibraryAccessClaim(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011")),
        kind: .selectionMutation
    )
    let second = SkillLibraryAccessClaim(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012")),
        kind: .read
    )
    let reducer = SkillLibraryAccessReducer()
    let active = SkillLibraryAccessState.active(owner: first, waiting: [second])

    let cancelled = try reducer.reduce(state: active, action: .cancel(first.id))

    #expect(cancelled.state == .active(owner: second, waiting: []))
    #expect(cancelled.effects == [.cancel(first.id), .grant(second)])
}

@Test
func skillPreparationWaiterCancellationWinsBeforeContinuationInstallation() async {
    let resolution = SkillLibraryPreparationResolution()
    #expect(resolution.resolve(.failure(CancellationError())))

    await #expect(throws: CancellationError.self) {
        try await withCheckedThrowingContinuation { continuation in
            resolution.install(continuation)
        }
    }
    #expect(resolution.resolve(.success(())) == false)
}

@Test
func skillLibrarySerializesReentrantStateMutationsWithoutLosingUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let persistence = BlockingSkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()

    let first = Task {
        try await library.setSelected(skillName: "first", selected: true)
    }
    await persistence.waitForFirstSaveToStart()
    let second = Task {
        try await library.setSelected(skillName: "second", selected: true)
    }

    var queued = false
    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await library.accessState, waiting.count == 1 {
            queued = true
            break
        }
        await Task.yield()
    }
    #expect(queued)
    #expect(await persistence.counts().loads == 1)

    await persistence.releaseFirstSave()
    try await first.value
    try await second.value

    let state = await persistence.currentState()
    #expect(state.selectionOverrides["first"] == true)
    #expect(state.selectionOverrides["second"] == true)
    #expect(await persistence.counts().saves == 2)
}

@Test
func skillLibrariesSharingWorkspaceSerializeStateMutationsWithoutLosingUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let persistence = BlockingSkillStatePersistenceFixture()
    let firstLibrary = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    let secondLibrary = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await firstLibrary.prepare()
    try await secondLibrary.prepare()

    let first = Task {
        try await firstLibrary.setSelected(skillName: "first", selected: true)
    }
    await persistence.waitForFirstSaveToStart()
    let second = Task {
        try await secondLibrary.setSelected(skillName: "second", selected: true)
    }

    var queued = false
    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await firstLibrary.accessState, waiting.count == 1 {
            queued = true
            break
        }
        await Task.yield()
    }
    #expect(queued)
    #expect(await persistence.counts().loads == 1)

    await persistence.releaseFirstSave()
    try await first.value
    try await second.value

    let state = await persistence.currentState()
    #expect(state.selectionOverrides["first"] == true)
    #expect(state.selectionOverrides["second"] == true)
    #expect(await persistence.counts().saves == 2)
}

@Test
func skillLibrariesSharingWorkspaceSerializeSecretMutationsAcrossStoreInstances() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let blockingStore = BlockingSecretStore()
    let countingStore = CountingSecretStore()
    let firstLibrary = SkillLibrary(workspace: workspace, secretStore: blockingStore)
    let secondLibrary = SkillLibrary(workspace: workspace, secretStore: countingStore)

    let first = Task {
        try await firstLibrary.saveSecret("first-value", for: "first")
    }
    await blockingStore.waitForWriteToStart()
    let second = Task {
        try await secondLibrary.saveSecret("second-value", for: "second")
    }

    var queued = false
    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await firstLibrary.accessState,
           waiting.first?.kind == .secretMutation {
            queued = true
            break
        }
        await Task.yield()
    }
    #expect(queued)
    #expect(await countingStore.recordedWriteCount() == 0)

    await blockingStore.releaseWrite()
    try await first.value
    try await second.value

    #expect(await blockingStore.recordedWrites().count == 1)
    #expect(await countingStore.recordedWriteCount() == 1)
}

@Test
func cancelledSkillLibraryMutationLeavesTheQueueWithoutExecuting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let persistence = BlockingSkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()

    let first = Task {
        try await library.setSelected(skillName: "first", selected: true)
    }
    await persistence.waitForFirstSaveToStart()
    let cancelled = Task {
        try await library.setSelected(skillName: "cancelled", selected: true)
    }

    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await library.accessState, waiting.count == 1 {
            break
        }
        await Task.yield()
    }
    cancelled.cancel()

    var cancellationRemoved = false
    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await library.accessState, waiting.isEmpty {
            cancellationRemoved = true
            break
        }
        await Task.yield()
    }
    #expect(cancellationRemoved)

    await persistence.releaseFirstSave()
    try await first.value
    await #expect(throws: CancellationError.self) {
        try await cancelled.value
    }

    let state = await persistence.currentState()
    #expect(state.selectionOverrides["first"] == true)
    #expect(state.selectionOverrides["cancelled"] == nil)
    #expect(await persistence.counts().saves == 1)
}

@Test
func skillLibraryReadWaitsForInFlightMutationAndObservesCommittedState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
    let persistence = BlockingSkillStatePersistenceFixture()
    let library = SkillLibrary(
        workspace: workspace,
        fileRemoval: .foundation,
        statePersistenceBoundary: persistence.boundary()
    )
    try await library.prepare()

    let mutation = Task {
        try await library.setSelected(skillName: "visible-after-commit", selected: true)
    }
    await persistence.waitForFirstSaveToStart()
    let read = Task {
        try await library.snapshot()
    }

    var readQueued = false
    for _ in 0..<1_000 {
        if case .active(_, let waiting) = await library.accessState,
              waiting.first?.kind == .read {
            readQueued = true
            break
        }
        await Task.yield()
    }
    #expect(readQueued)
    #expect(await persistence.counts().loads == 1)

    await persistence.releaseFirstSave()
    try await mutation.value
    _ = try await read.value

    #expect(await persistence.counts().loads == 2)
    #expect(await persistence.currentState().selectionOverrides["visible-after-commit"] == true)
}

@Test
func skillStateStoreRoundTripsThroughPersistencePolicy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    let store = SkillStateStore(fileURL: root.appendingPathComponent("config/skills/state.json"))

    let state = SkillState(
        updatedAt: Date(timeIntervalSince1970: 123),
        selectionOverrides: ["built-in": true]
    )

    try await store.save(state)
    let loaded = try await store.load()

    #expect(loaded.selectionOverrides == ["built-in": true])
    #expect(loaded.updatedAt == Date(timeIntervalSince1970: 123))
}

@Test
func skillStateStoreRejectsOutputThatCannotBeReadBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("config/skills/state.json")
    let store = SkillStateStore(fileURL: fileURL)
    let oversizedKey = String(
        repeating: "a",
        count: SkillLocalFileLimits.maximumStateBytes
    )

    await #expect(throws: AgentError.self) {
        try await store.save(
            SkillState(selectionOverrides: [oversizedKey: true])
        )
    }
    #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
}



@Test
func skillStateStoreCreatesOneStableInitialRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let fileURL = root.appendingPathComponent("config/skills/state.json")
    let store = SkillStateStore(fileURL: fileURL)

    let first = try await store.load()
    let second = try await store.load()

    #expect(first == second)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func skillStatePersistenceBoundaryDelegatesAndPropagatesFailures() async throws {
    let fixture = SkillStatePersistenceFixture()
    let boundary = fixture.boundary()
    let updated = SkillState(
        updatedAt: Date(timeIntervalSince1970: 2),
        selectionOverrides: ["reviewer": true]
    )

    try await boundary.prepare()
    try await boundary.save(updated)
    #expect(try await boundary.load() == updated)
    #expect(await fixture.recordedPreparationCount() == 1)

    await fixture.rejectFutureSaves()
    await #expect(throws: SkillStatePersistenceFixture.FixtureError.self) {
        try await boundary.save(SkillState(updatedAt: Date(timeIntervalSince1970: 3)))
    }
}
