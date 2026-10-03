import Foundation

struct SkillStatePersistenceBoundary: Sendable {
    private let prepareOperation: @Sendable () async throws -> Void
    private let loadOperation: @Sendable () async throws -> SkillState
    private let saveOperation: @Sendable (SkillState) async throws -> Void

    init(
        prepare: @escaping @Sendable () async throws -> Void,
        load: @escaping @Sendable () async throws -> SkillState,
        save: @escaping @Sendable (SkillState) async throws -> Void
    ) {
        self.prepareOperation = prepare
        self.loadOperation = load
        self.saveOperation = save
    }

    init(store: SkillStateStore) {
        self.init(
            prepare: { try await store.prepare() },
            load: { try await store.load() },
            save: { state in try await store.save(state) }
        )
    }

    func prepare() async throws {
        try await prepareOperation()
    }

    func load() async throws -> SkillState {
        try await loadOperation()
    }

    func save(_ state: SkillState) async throws {
        try await saveOperation(state)
    }
}
