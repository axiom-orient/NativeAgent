import Foundation
import KnowledgeRuntime
import KnowledgeHealth
import EvidenceIndex
import WorkWiki

/// Lower-level runtime ownership used by ASKClient. Commands and queries belong
/// to ASKClient; this actor coordinates mutations and caches WorkWiki runtimes.
public actor ASKApplicationRuntime {
    private static let workWikiRuntimeCacheLimit = 16
    private var workWikiRuntimes: [ASKApplicationConfiguration: ASKWorkWikiRuntime] = [:]
    private var workWikiRuntimeOrder: [ASKApplicationConfiguration] = []

    public init() {}

    /// Reserves every resource root for one process-local mutation. Effects must
    /// release the returned lease on every exit path.
    public func beginMutation(
        actionID: String,
        configuration requested: ASKApplicationConfiguration,
        additionalProtectedRoots: [URL] = []
    ) async throws -> ASKApplicationMutationLease {
        try await ASKApplicationMutationCoordinator.shared.begin(
            actionID: actionID,
            configuration: requested,
            additionalProtectedRoots: additionalProtectedRoots
        )
    }

    /// Releases a mutation lane. `false` exposes a mismatched or stale lease
    /// instead of silently masking an ownership error.
    @discardableResult
    public func finishMutation(_ lease: ASKApplicationMutationLease) async -> Bool {
        await ASKApplicationMutationCoordinator.shared.finish(lease)
    }

    public func activeMutationActionID(configuration requested: ASKApplicationConfiguration) async -> String? {
        await ASKApplicationMutationCoordinator.shared.activeActionID(configuration: requested)
    }

    public func isActiveMutation(_ lease: ASKApplicationMutationLease) async -> Bool {
        await ASKApplicationMutationCoordinator.shared.isActive(lease)
    }

    /// Verify an active lease covers every requested output/resource root.
    public func isActiveMutation(_ lease: ASKApplicationMutationLease, protecting roots: [URL]) async -> Bool {
        await ASKApplicationMutationCoordinator.shared.isActive(lease, protecting: roots)
    }

    public func workWikiRuntime(configuration requested: ASKApplicationConfiguration) async throws -> ASKWorkWikiRuntime {
        guard let evidenceIndexURL = requested.evidenceIndexURL else {
            throw ASKApplicationError.missingEvidenceIndexPath
        }
        if let cached = workWikiRuntimes[requested] { return cached }
        let evidenceIndex = try await ASKEvidenceIndex.open(workspaceURL: evidenceIndexURL)
        let created = ASKWorkWikiRuntime(
            maintainer: ASKRuntimeKnowledgeMaintainer(root: requested.vaultURL),
            evidenceIndex: evidenceIndex,
            storageHealthRuntime: ASKKnowledgeStorageHealthIntegration.makeWorkWikiStorageHealthRuntime(
                vaultURL: requested.vaultURL,
                evidenceIndex: evidenceIndex
            )
        )
        workWikiRuntimes[requested] = created
        workWikiRuntimeOrder.append(requested)
        while workWikiRuntimeOrder.count > Self.workWikiRuntimeCacheLimit {
            let evicted = workWikiRuntimeOrder.removeFirst()
            workWikiRuntimes[evicted] = nil
        }
        return created
    }

}
