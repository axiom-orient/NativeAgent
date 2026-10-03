import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

private actor FlakyReleaseClaimStore: SessionExecutionClaimStore {
    private var owners: [String: String] = [:]
    private var remainingReleaseFailures: Int

    init(releaseFailures: Int = 1) {
        self.remainingReleaseFailures = releaseFailures
    }

    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        guard owners[sessionID] == nil else {
            throw AgentError.sessionBusy(sessionID)
        }
        let claim = SessionExecutionClaim(sessionID: sessionID, claimID: UUID().uuidString)
        owners[sessionID] = claim.claimID
        return claim
    }

    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        guard owners[claim.sessionID] == claim.claimID else {
            throw AgentError.persistenceFailure("Claim is not owned: \(claim.sessionID)")
        }
        if remainingReleaseFailures > 0 {
            remainingReleaseFailures -= 1
            throw AgentError.persistenceFailure("Injected transient claim release failure.")
        }
        owners.removeValue(forKey: claim.sessionID)
    }

    func owns(sessionID: String) -> Bool {
        owners[sessionID] != nil
    }
}

private protocol SafetySessionStore: SessionRuntimePersistence {}

private extension SafetySessionStore {
    func prepare() async throws {}
    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? { nil }
    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? { nil }
    func persistArtifact(
        sessionID: String,
        artifact: ArtifactWriteRequest,
        createdAt: Date
    ) async throws -> ArtifactRecord {
        throw AgentError.persistenceFailure("not used")
    }
    func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws {
        throw AgentError.persistenceFailure("not used")
    }
    func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        throw AgentError.notFound("not used")
    }
    func sandboxRootURL() async throws -> URL { FileManager.default.temporaryDirectory }
    func sessionDirectoryURL(sessionID: String) async throws -> URL {
        FileManager.default.temporaryDirectory
    }
}

private protocol SafetyTransactionalStore: SafetySessionStore, RuntimeTransactionalSessionStore {}

private extension SafetyTransactionalStore {
    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {}
    func commit(_ transaction: SessionPersistenceTransaction) async throws {}
}

private protocol SafetyEffectStore: EffectLedgerStore {}

private extension SafetyEffectStore {
    func loadEffect(
        sessionID: String,
        scope: EffectScope,
        key: String
    ) async throws -> EffectRecord? { nil }
    func saveEffect(_ effect: EffectRecord) async throws {}
}

private protocol SafetyClaimStore: SessionExecutionClaimStore {}

private extension SafetyClaimStore {
    func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        SessionExecutionClaim(sessionID: sessionID, claimID: "test-claim")
    }
    func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {}
}

private struct MissingClaimStore: SessionRuntimeStore, SafetyTransactionalStore, SafetyEffectStore, SessionRuntimeAdmissionStore {
    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? { nil }
}

private struct NonAtomicRuntimeStore: SessionRuntimeStore, SafetyTransactionalStore, SafetyEffectStore, SessionRuntimeAdmissionStore, SafetyClaimStore {
    func loadSessionRuntimeAdmission(sessionID: String) async throws -> SessionRuntimeAdmission? { nil }
}

private func executionSafetyTempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-execution-safety-\(UUID().uuidString)", isDirectory: true)
}

@Test
func kernelFileClaimPreventsTwoStoresFromOwningOneSession() async throws {
    let root = executionSafetyTempRoot()
    let firstStore = ApplicationSupportSessionStore(rootURL: root)
    let secondStore = ApplicationSupportSessionStore(rootURL: root)
    let sessionID = "shared-session"
    let firstClaim = try await firstStore.acquireExecutionClaim(sessionID: sessionID)

    do {
        _ = try await secondStore.acquireExecutionClaim(sessionID: sessionID)
        Issue.record("A second store acquired a session while the first claim was active.")
    } catch let error as AgentError {
        guard case .sessionBusy(let busySessionID) = error else {
            Issue.record("Expected sessionBusy, received \(error).")
            return
        }
        #expect(busySessionID == sessionID)
    }

    try await firstStore.releaseExecutionClaim(firstClaim)
    let secondClaim = try await secondStore.acquireExecutionClaim(sessionID: sessionID)
    try await secondStore.releaseExecutionClaim(secondClaim)
}

@Test
func productionSafetyRejectsMissingSharedClaimBoundary() throws {
    let bareStore = MissingClaimStore()

    #expect(throws: AgentError.self) {
        try SessionCoordinator(
            modelClient: ScriptedModelClient(),
            approvalRouter: AllowAllApprovalRouter(),
            runtimeStore: bareStore,
            toolPacks: [],
            configuration: RuntimeConfiguration(safetyPolicy: .durable)
        )
    }
}

@Test
func effectLedgerIsRequiredByTheSessionRuntimeStoreType() throws {
    // SessionRuntimeStore inherits EffectLedgerStore, so a store without an
    // effect ledger cannot satisfy the canonical coordinator entry at compile
    // time. This preserves the old ledgerRequired fail-closed behavior
    // structurally instead of through MutationEffectSafety.
    let _: any SessionRuntimeStore = NonAtomicRuntimeStore()
}

@Test
func forkRequiresAtomicRuntimeStore() throws {
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: NonAtomicRuntimeStore(),
        toolPacks: []
    )
    let store: any SessionRuntimeStore = NonAtomicRuntimeStore()
    #expect((store as? any RuntimeAtomicSessionForkStore) == nil)
    _ = coordinator
}

@Test
func failedClaimReleaseCanBeRetriedWithoutLosingOwnership() async throws {
    let root = executionSafetyTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let claimStore = FlakyReleaseClaimStore()
    let store = ApplicationSupportSessionStore(
        rootURL: root,
        executionClaimStore: claimStore
    )
    let coordinator = try SessionCoordinator(
        modelClient: ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "done")
        ]),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        configuration: RuntimeConfiguration(safetyPolicy: .durable),
        idGenerator: { "claim-release-session" }
    )

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.startSession(userPrompt: "start")
    }
    #expect(await claimStore.owns(sessionID: "claim-release-session"))

    await #expect(throws: AgentError.self) {
        _ = try await coordinator.run(sessionID: "claim-release-session")
    }

    #expect(try await coordinator.retryPendingExecutionClaimRelease(
        sessionID: "claim-release-session"
    ))
    #expect(await claimStore.owns(sessionID: "claim-release-session") == false)
    #expect(try await coordinator.retryPendingExecutionClaimRelease(
        sessionID: "claim-release-session"
    ) == false)

    let persisted = try #require(
        try await store.loadSnapshot(sessionID: "claim-release-session")
    )
    #expect(persisted.status == .completed)
}

@Test
func recoverySafetyRejectsMissingSharedClaimBoundary() throws {
    #expect(throws: AgentError.self) {
        try SessionRecoveryReader(
            runtimeStore: MissingClaimStore(),
            executionClaimStore: nil,
            executionAuthority: SessionExecutionAuthority(),
            toolPacks: [],
            configuration: RuntimeConfiguration(safetyPolicy: .durable)
        )
    }
}
