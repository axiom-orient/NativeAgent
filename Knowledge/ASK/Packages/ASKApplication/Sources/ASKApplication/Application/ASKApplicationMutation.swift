import Foundation

/// Opaque ownership token for one workspace mutation lane.
public struct ASKApplicationMutationLease: Equatable, Sendable {
    public let actionID: String
    public let configuration: ASKApplicationConfiguration
    let token: UUID
    let protectedRoots: [URL]

    init(actionID: String, configuration: ASKApplicationConfiguration, token: UUID, additionalProtectedRoots: [URL] = []) {
        self.actionID = actionID
        self.configuration = configuration
        self.token = token
        self.protectedRoots = ([configuration.vaultURL] + [configuration.evidenceIndexURL].compactMap { $0 }
            + additionalProtectedRoots).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }
}

enum ASKApplicationMutationState: Equatable, Sendable {
    case idle
    case active(ASKApplicationMutationLease)
}

enum ASKApplicationMutationEvent: Equatable, Sendable {
    case begin(ASKApplicationMutationLease)
    case finish(ASKApplicationMutationLease)
}

enum ASKApplicationMutationRejection: Equatable, Sendable {
    case mutationInProgress(actionID: String)
    case staleLease
}

enum ASKApplicationMutationDecision: Equatable, Sendable {
    case accepted(ASKApplicationMutationState)
    case rejected(ASKApplicationMutationRejection)
}

/// Pure mutation-lane reducer. It owns no I/O and cannot hide a failure.
enum ASKApplicationMutationReducer {
    static func reduce(
        state: ASKApplicationMutationState,
        event: ASKApplicationMutationEvent
    ) -> ASKApplicationMutationDecision {
        switch (state, event) {
        case (.idle, .begin(let lease)):
            return .accepted(.active(lease))
        case (.active(let current), .begin):
            return .rejected(.mutationInProgress(actionID: current.actionID))
        case (.active(let current), .finish(let lease)) where current == lease:
            return .accepted(.idle)
        case (.idle, .finish), (.active, .finish):
            return .rejected(.staleLease)
        }
    }
}

/// Process-wide mutation ownership over overlapping canonical resource roots.
///
/// `ASKApplicationRuntime` values are cheap composition facades and callers may
/// create more than one. Keeping the lane here prevents separate clients or
/// agent instances from concurrently mutating the same workspace.
actor ASKApplicationMutationCoordinator {
    static let shared = ASKApplicationMutationCoordinator()

    private var states: [ASKApplicationConfiguration: ASKApplicationMutationState] = [:]

    func begin(
        actionID: String,
        configuration requested: ASKApplicationConfiguration,
        additionalProtectedRoots: [URL] = []
    ) throws -> ASKApplicationMutationLease {
        let configuration = ASKApplicationConfiguration(vaultURL: requested.vaultURL, evidenceIndexURL: requested.evidenceIndexURL)
        let lease = ASKApplicationMutationLease(
            actionID: actionID,
            configuration: configuration,
            token: UUID(),
            additionalProtectedRoots: additionalProtectedRoots
        )
        if let active = conflictingLease(roots: lease.protectedRoots) {
            throw ASKApplicationError.mutationInProgress(actionID: active.actionID)
        }
        let state = states[configuration] ?? .idle
        switch ASKApplicationMutationReducer.reduce(state: state, event: .begin(lease)) {
        case .accepted(let next):
            states[configuration] = next
            return lease
        case .rejected(.mutationInProgress(let actionID)):
            throw ASKApplicationError.mutationInProgress(actionID: actionID)
        case .rejected(.staleLease):
            throw ASKApplicationError.invalidMutationTransition
        }
    }

    func finish(_ lease: ASKApplicationMutationLease) -> Bool {
        let state = states[lease.configuration] ?? .idle
        switch ASKApplicationMutationReducer.reduce(state: state, event: .finish(lease)) {
        case .accepted(.idle):
            states.removeValue(forKey: lease.configuration)
            return true
        case .accepted(.active), .rejected:
            return false
        }
    }

    func activeActionID(configuration: ASKApplicationConfiguration) -> String? {
        conflictingLease(roots: [configuration.vaultURL] + [configuration.evidenceIndexURL].compactMap { $0 })?.actionID
    }

    func isActive(_ lease: ASKApplicationMutationLease, protecting roots: [URL] = []) -> Bool {
        guard states[lease.configuration] == .active(lease) else { return false }
        return roots.allSatisfy { requested in
            let path = requested.standardizedFileURL.resolvingSymlinksInPath().path
            return lease.protectedRoots.contains { root in
                path == root.path || path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
            }
        }
    }

    private func conflictingLease(roots: [URL]) -> ASKApplicationMutationLease? {
        let paths = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        return states.values.compactMap { state -> ASKApplicationMutationLease? in
            guard case .active(let lease) = state else { return nil }
            let overlaps = lease.protectedRoots.contains { root in
                let path = root.path
                return paths.contains { other in
                    path == other || other.hasPrefix(path == "/" ? path : path + "/")
                        || path.hasPrefix(other == "/" ? other : other + "/")
                }
            }
            return overlaps ? lease : nil
        }.sorted { $0.actionID < $1.actionID }.first
    }
}
