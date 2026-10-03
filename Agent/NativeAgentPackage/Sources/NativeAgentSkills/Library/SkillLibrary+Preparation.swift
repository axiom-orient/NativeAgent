import Foundation
import NativeAgentDomain

enum SkillLibraryPreparationState {
    case idle
    case preparing
    case prepared
}

final class SkillLibraryPreparationResolution: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Void, any Error>

    private enum State {
        case empty
        case waiting(Continuation)
        case resolved(Result<Void, any Error>)
        case finished
    }

    // Foundation-only so NativeAgentSkills keeps the same synchronization semantics on Linux
    // instead of depending on Apple's `os` module just for this small continuation state machine.
    private let lock = NSLock()
    private var state = State.empty

    func install(_ continuation: Continuation) {
        let immediate: Result<Void, any Error>?
        lock.lock()
        switch state {
        case .empty:
            state = .waiting(continuation)
            immediate = nil
        case .resolved(let result):
            state = .finished
            immediate = result
        case .waiting, .finished:
            immediate = .failure(
                AgentError.invariantViolation(
                    "Skill library preparation continuation was installed more than once."
                )
            )
        }
        lock.unlock()

        if let immediate {
            continuation.resume(with: immediate)
        }
    }

    @discardableResult
    func resolve(_ result: Result<Void, any Error>) -> Bool {
        let continuation: Continuation?
        let accepted: Bool
        lock.lock()
        switch state {
        case .empty:
            state = .resolved(result)
            continuation = nil
            accepted = true
        case .waiting(let waiting):
            state = .finished
            continuation = waiting
            accepted = true
        case .resolved, .finished:
            continuation = nil
            accepted = false
        }
        lock.unlock()

        continuation?.resume(with: result)
        return accepted
    }
}

extension SkillLibrary {
    public func prepare() async throws {
        try Task.checkCancellation()
        switch preparationState {
        case .prepared:
            return
        case .preparing:
            try await waitForPreparation()
            return
        case .idle:
            preparationState = .preparing
        }

        do {
            try fileManager.createDirectory(
                at: workspace.userSkillsRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: workspace.supportRootURL,
                withIntermediateDirectories: true
            )
            try await stateStore.prepare()
            try await withLibraryAccess(kind: .workspaceRecovery) {
                try await workspaceTransaction.recoverIfNeeded()
            }
        } catch {
            finishPreparation(.failure(error))
            throw error
        }
        finishPreparation(.success(()))
        try Task.checkCancellation()
    }

    func waitForPreparation() async throws {
        let resolution = SkillLibraryPreparationResolution()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolution.install(continuation)
                preparationWaiters.append(resolution)
            }
        } onCancel: {
            resolution.resolve(.failure(CancellationError()))
        }
        try Task.checkCancellation()
    }

    func finishPreparation(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            preparationState = .prepared
        case .failure:
            preparationState = .idle
        }
        let waiters = preparationWaiters
        preparationWaiters.removeAll()
        for waiter in waiters {
            waiter.resolve(result)
        }
    }
}
