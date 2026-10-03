import NativeAgentDomain
import Foundation

public actor SkillLibrary {
    let workspace: SkillWorkspace
    let fileManager: FileManager
    let bundle: Bundle
    let secretStore: any SkillSecretStore
    let stateStore: SkillStatePersistenceBoundary
    let remoteFetcher: any RemoteSkillFetcher
    let now: @Sendable () -> Date
    let pathPolicy: SkillPathPolicy
    let fileImportPolicy: SkillFileImportPolicy
    let fileRemoval: SkillFileRemoval
    let selectionReducer: SkillLibrarySelectionReducer
    let snapshotBuilder: SkillLibrarySnapshotBuilder
    let workspaceTransaction: SkillWorkspaceTransactionExecutor
    let accessCoordinator: SkillWorkspaceAccessCoordinator
    let accessRootKey: String
    var preparationState = SkillLibraryPreparationState.idle
    var preparationWaiters: [SkillLibraryPreparationResolution] = []

    var accessState: SkillLibraryAccessState {
        get async {
            await accessCoordinator.state(for: accessRootKey)
        }
    }

    public init(
        workspace: SkillWorkspace,
        bundle: Bundle = .main,
        secretStore: (any SkillSecretStore)? = nil,
        stateStore: SkillStateStore? = nil,
        remoteFetcher: any RemoteSkillFetcher = URLSessionRemoteSkillFetcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            workspace: workspace,
            fileManager: FileManager(),
            bundle: bundle,
            secretStore: secretStore,
            stateStore: stateStore,
            remoteFetcher: remoteFetcher,
            now: now,
            fileRemoval: .foundation
        )
    }

    init(
        workspace: SkillWorkspace,
        fileManager: sending FileManager,
        bundle: Bundle? = nil,
        secretStore: (any SkillSecretStore)? = nil,
        stateStore: SkillStateStore? = nil,
        remoteFetcher: any RemoteSkillFetcher = URLSessionRemoteSkillFetcher(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileRemoval: SkillFileRemoval,
        statePersistenceBoundary: SkillStatePersistenceBoundary? = nil
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.accessCoordinator = .shared
        self.accessRootKey = workspace.userSkillsRootURL.standardizedFileURL.path
        self.bundle = bundle ?? .main
        self.secretStore = secretStore ?? SkillSecrets.makeDefaultStore(workspace: workspace)
        let resolvedStateStore: SkillStatePersistenceBoundary
        if let statePersistenceBoundary {
            resolvedStateStore = statePersistenceBoundary
        } else {
            let store = stateStore ?? SkillStateStore(fileURL: workspace.stateFileURL)
            resolvedStateStore = SkillStatePersistenceBoundary(store: store)
        }
        self.stateStore = resolvedStateStore
        self.remoteFetcher = remoteFetcher
        self.now = now
        let pathPolicy = SkillPathPolicy(workspace: workspace)
        let fileImportPolicy = SkillFileImportPolicy(
            fileManager: fileManager, pathPolicy: pathPolicy)
        self.pathPolicy = pathPolicy
        self.fileImportPolicy = fileImportPolicy
        self.workspaceTransaction = SkillWorkspaceTransactionExecutor(
            workspace: workspace,
            fileManager: fileManager,
            pathPolicy: pathPolicy,
            fileImportPolicy: fileImportPolicy,
            stateStore: resolvedStateStore,
            fileRemoval: fileRemoval
        )
        self.fileRemoval = fileRemoval
        self.selectionReducer = SkillLibrarySelectionReducer(now: now)
        self.snapshotBuilder = SkillLibrarySnapshotBuilder(groupOrder: Self.groupOrder)
    }

    init(
        workspace: SkillWorkspace,
        bundle: Bundle? = nil,
        secretStore: (any SkillSecretStore)? = nil,
        stateStore: SkillStateStore? = nil,
        remoteFetcher: any RemoteSkillFetcher = URLSessionRemoteSkillFetcher(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileRemoval: SkillFileRemoval,
        statePersistenceBoundary: SkillStatePersistenceBoundary? = nil
    ) {
        self.init(
            workspace: workspace,
            fileManager: FileManager(),
            bundle: bundle,
            secretStore: secretStore,
            stateStore: stateStore,
            remoteFetcher: remoteFetcher,
            now: now,
            fileRemoval: fileRemoval,
            statePersistenceBoundary: statePersistenceBoundary
        )
    }

    nonisolated static func groupOrder(_ group: String) -> Int {
        switch group {
        case "built-in": return 0
        case "featured": return 1
        case "custom": return 2
        default: return 3
        }
    }

}
