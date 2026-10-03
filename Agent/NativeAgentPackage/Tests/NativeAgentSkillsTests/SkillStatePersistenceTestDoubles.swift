import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

actor SkillStatePersistenceFixture {
    enum FixtureError: Error {
        case saveRejected
    }

    private var state = SkillState(updatedAt: Date(timeIntervalSince1970: 1))
    private var rejectSave = false
    private var prepareCount = 0
    private var saveAttemptCount = 0

    nonisolated func boundary() -> SkillStatePersistenceBoundary {
        SkillStatePersistenceBoundary(
            prepare: { await self.recordPreparation() },
            load: { await self.currentState() },
            save: { state in try await self.persist(state) }
        )
    }

    func rejectFutureSaves() {
        rejectSave = true
    }

    func recordedPreparationCount() -> Int {
        prepareCount
    }

    func recordedSaveAttemptCount() -> Int {
        saveAttemptCount
    }

    private func recordPreparation() {
        prepareCount += 1
    }

    private func currentState() -> SkillState {
        state
    }

    private func persist(_ state: SkillState) throws {
        saveAttemptCount += 1
        guard !rejectSave else { throw FixtureError.saveRejected }
        self.state = state
    }
}


actor BlockingSkillStatePersistenceFixture {
    private var state = SkillState(updatedAt: Date(timeIntervalSince1970: 1))
    private var loadCount = 0
    private var saveAttemptCount = 0
    private var firstSaveStarted = false
    private var firstSaveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveRelease: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    nonisolated func boundary() -> SkillStatePersistenceBoundary {
        SkillStatePersistenceBoundary(
            prepare: {},
            load: { await self.load() },
            save: { state in await self.save(state) }
        )
    }

    func waitForFirstSaveToStart() async {
        if firstSaveStarted { return }
        await withCheckedContinuation { continuation in
            firstSaveStartWaiters.append(continuation)
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

    func counts() -> (loads: Int, saves: Int) {
        (loadCount, saveAttemptCount)
    }

    func currentState() -> SkillState {
        state
    }

    private func load() -> SkillState {
        loadCount += 1
        return state
    }

    private func save(_ updatedState: SkillState) async {
        saveAttemptCount += 1
        if saveAttemptCount == 1 {
            firstSaveStarted = true
            let waiters = firstSaveStartWaiters
            firstSaveStartWaiters.removeAll()
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
        state = updatedState
    }
}
