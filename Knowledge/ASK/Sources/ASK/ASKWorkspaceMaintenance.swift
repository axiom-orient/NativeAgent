import Foundation
import ASKApplication
import PageIndex
import KnowledgeRuntime

extension ASKClient {
    /// Runtime-owned derived database paths, for use only inside maintenance.
    public var rebuildableDatabaseURLs: [URL] {
        ASKRuntime(root: configuration.resolvedVaultURL).rebuildableDatabaseURLs
    }

    /// Holds the same mutation authority as ordinary commands across backup,
    /// recovery and multiple command effects. Does not bypass plan validation.
    /// The session rejects concurrent use and becomes unusable after this scope.
    public func withWorkspaceMaintenance<Value: Sendable>(
        actionID: String,
        additionalProtectedRoots: [URL] = [],
        operation: @Sendable (ASKWorkspaceMaintenance) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let lease = try await application.beginMutation(
            actionID: actionID,
            configuration: ASKApplicationConfiguration(vaultURL: configuration.resolvedVaultURL,
                                                 evidenceIndexURL: configuration.resolvedIndexURL),
            additionalProtectedRoots: [configuration.workspaceURL, configuration.resolvedProductWorkspaceURL] + additionalProtectedRoots
        )
        let session = ASKWorkspaceMaintenance(client: self, lease: lease)
        let result: Result<Value, Error>
        do {
            try Task.checkCancellation()
            result = .success(try await operation(session))
        }
        catch { result = .failure(error) }
        await session.close()
        guard await application.finishMutation(lease) else {
            var context = ["actionID": actionID]
            if case .failure(let error) = result { context["primaryError"] = String(describing: error) }
            throw ASKDiagnostic(code: .conflict, operation: .repair,
                message: "Workspace maintenance lease could not be released", context: context,
                recovery: .inspectStorage)
        }
        return try result.get()
    }
}

/// A bounded, scope-owned execution gate; canonical state still belongs to the
/// existing domain runtimes. No public initializer or reusable ownership token.
public actor ASKWorkspaceMaintenance {
    private let client: ASKClient
    private let lease: ASKApplicationMutationLease
    private var active = false
    private var closing = false
    private var closeWaiter: CheckedContinuation<Void, Never>?

    init(client: ASKClient, lease: ASKApplicationMutationLease) {
        self.client = client
        self.lease = lease
    }

    public func apply(_ command: ASKCommand) async throws -> ASKApplyOutcome {
        try begin()
        defer { finish() }
        let plan = try client.plan(command)
        return try await client.apply(plan, maintenanceLease: lease)
    }

    public func query(_ query: ASKQuery) async throws -> ASKQueryResult {
        try begin()
        defer { finish() }
        let selected = query.workspaceSelection
        let paths = ASKCommandPlanner.context(for: selected, configuration: client.configuration)
        guard ASKApplicationConfiguration(vaultURL: paths.vaultURL, evidenceIndexURL: paths.indexURL) == lease.configuration else {
            throw unavailable("Maintenance query must use the reserved workspace")
        }
        return try await client.query(query)
    }

    /// Current and retained historical artifacts pin their original source bytes.
    /// SourceIndexStore, not the UI, determines the retained version set.
    public func retainedSourcePaths() async throws -> [String] {
        try begin()
        defer { finish() }
        let store = try SourceIndexStore(workspaceURL: client.configuration.resolvedIndexURL)
        return try await store.retainedSourcePaths()
    }

    /// Trusted host maintenance API; no command/query/MCP surface is added.
    /// The caller supplies only raw roots already reserved by this maintenance
    /// scope. The sole write footprint is the configured PageIndex workspace.
    @discardableResult
    public func relocateSourcePaths(
        _ replacements: [String: URL], allowedDestinationRoots: [URL]
    ) async throws -> Int {
        try begin()
        defer { finish() }
        let workspacePath = ASKManagedRouteContainment.resolvedPath(client.configuration.workspaceURL)
        let indexPath = ASKManagedRouteContainment.resolvedPath(client.configuration.resolvedIndexURL)
        guard indexPath.hasPrefix(workspacePath + "/") else {
            throw ASKDiagnostic(code: .invalidRequest, operation: .repair,
                message: "Source relocation index must remain inside the reserved workspace",
                recovery: .correctInput)
        }
        let store = try SourceIndexStore(workspaceURL: client.configuration.resolvedIndexURL)
        return try await store.relocateSourcePaths(replacements, allowedDestinationRoots: allowedDestinationRoots)
    }

    func close() async {
        closing = true
        if active {
            await withCheckedContinuation { closeWaiter = $0 }
        }
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !closing, !active else { throw unavailable("Maintenance session is closed or already executing") }
        active = true
    }

    private func finish() {
        active = false
        closeWaiter?.resume()
        closeWaiter = nil
    }

    private func unavailable(_ message: String) -> ASKDiagnostic {
        ASKDiagnostic(code: .conflict, operation: .repair, message: message,
            context: ["actionID": lease.actionID], recovery: .retry)
    }
}