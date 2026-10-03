import Foundation

/// Exclusive ownership of one durable goal advancement.
public struct GoalExecutionClaim: Hashable, Sendable {
    public let goalID: String
    public let claimID: String

    public init(goalID: String, claimID: String = UUID().uuidString) {
        self.goalID = GoalPath.sanitized(goalID)
        self.claimID = claimID
    }
}

/// Host-replaceable boundary for serializing goal execution.
///
/// A failed release must leave ownership intact so the caller can retry it.
/// The built-in file store implementation is process-local. A host that lets an
/// app and extension advance the same app-group goal root must inject a
/// cross-process implementation.
public protocol GoalExecutionClaimStore: Sendable {
    func acquireGoalExecutionClaim(goalID: String) async throws -> GoalExecutionClaim
    func releaseGoalExecutionClaim(_ claim: GoalExecutionClaim) async throws
}

public actor InMemoryGoalExecutionClaimStore: GoalExecutionClaimStore {
    private var claims: [String: GoalExecutionClaim] = [:]

    public init() {}

    public func acquireGoalExecutionClaim(goalID: String) throws -> GoalExecutionClaim {
        let clean = GoalPath.sanitized(goalID)
        guard claims[clean] == nil else {
            throw GoalError.goalBusy(clean)
        }
        let claim = GoalExecutionClaim(goalID: clean)
        claims[clean] = claim
        return claim
    }

    public func releaseGoalExecutionClaim(_ claim: GoalExecutionClaim) throws {
        guard claims[claim.goalID] == claim else {
            throw GoalError.invalidExecutionClaim(claim.goalID)
        }
        claims.removeValue(forKey: claim.goalID)
    }
}

actor GoalExecutionState {
    private var activeGoalIDs: Set<String> = []
    private var unreleasedClaims: [String: GoalExecutionClaim] = [:]

    func begin(goalID: String) throws {
        guard activeGoalIDs.contains(goalID) == false else {
            throw GoalError.goalBusy(goalID)
        }
        guard unreleasedClaims[goalID] == nil else {
            throw GoalError.storeFailure(
                "goal execution claim release is pending for \"\(goalID)\"; retry it before advancing the goal"
            )
        }
        activeGoalIDs.insert(goalID)
    }

    func end(goalID: String) {
        activeGoalIDs.remove(goalID)
    }

    func retainUnreleased(_ claim: GoalExecutionClaim) {
        unreleasedClaims[claim.goalID] = claim
    }

    func clearUnreleased(goalID: String) {
        unreleasedClaims.removeValue(forKey: goalID)
    }

    func unreleasedClaim(goalID: String) -> GoalExecutionClaim? {
        unreleasedClaims[goalID]
    }
}

private let processGoalExecutionClaimRegistry = ProcessGoalExecutionClaimRegistry()

private actor ProcessGoalExecutionClaimRegistry {
    private var claims: [String: GoalExecutionClaim] = [:]

    func acquire(namespace: String, goalID: String) throws -> GoalExecutionClaim {
        let key = storageKey(namespace: namespace, goalID: goalID)
        guard claims[key] == nil else {
            throw GoalError.goalBusy(goalID)
        }
        let claim = GoalExecutionClaim(goalID: goalID)
        claims[key] = claim
        return claim
    }

    func release(namespace: String, claim: GoalExecutionClaim) throws {
        let key = storageKey(namespace: namespace, goalID: claim.goalID)
        guard claims[key] == claim else {
            throw GoalError.invalidExecutionClaim(claim.goalID)
        }
        claims.removeValue(forKey: key)
    }

    private func storageKey(namespace: String, goalID: String) -> String {
        namespace + "\u{1F}" + GoalPath.sanitized(goalID)
    }
}

extension FileGoalSessionStore: GoalExecutionClaimStore {
    public func acquireGoalExecutionClaim(goalID: String) async throws -> GoalExecutionClaim {
        // Resolve the namespace only after the path exists. On iOS, resolving
        // a missing sandbox child can differ from resolving it after first save.
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw GoalError.storeFailure("failed to create goal execution root: \(error.localizedDescription)")
        }
        return try await processGoalExecutionClaimRegistry.acquire(
            namespace: executionClaimNamespace,
            goalID: GoalPath.sanitized(goalID)
        )
    }

    public func releaseGoalExecutionClaim(_ claim: GoalExecutionClaim) async throws {
        try await processGoalExecutionClaimRegistry.release(
            namespace: executionClaimNamespace,
            claim: claim
        )
    }

    private var executionClaimNamespace: String {
        rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
