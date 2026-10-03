import Foundation
import NativeAgentDomain

private func goalSessionFileURL(rootURL: URL, goalID: String) -> URL {
    rootURL.appendingPathComponent(
        GoalPath.sanitized(goalID) + ".goal.json",
        isDirectory: false
    )
}

public protocol GoalSessionStore: Sendable {
    func load(goalID: String) async throws -> GoalSession?
    func save(_ session: GoalSession) async throws
    func path(goalID: String) -> String
    func updateStatus(goalID: String, to status: GoalStatus) async throws -> GoalSession
}

public protocol GoalSessionListingStore: GoalSessionStore {
    func list() async throws -> [GoalSession]
}

/// Optional atomic compare-and-swap boundary used by the goal loop to preserve
/// host/user state changes that arrive while a turn is running.
public protocol GoalAtomicSessionStore: GoalSessionStore {
    func save(
        _ session: GoalSession,
        replacing expected: GoalSession?
    ) async throws -> Bool
}

public extension GoalSessionStore {
    @discardableResult
    func resume(goalID: String) async throws -> GoalSession {
        try await updateStatus(goalID: goalID, to: .active)
    }

    @discardableResult
    func pause(goalID: String) async throws -> GoalSession {
        try await updateStatus(goalID: goalID, to: .paused)
    }

    @discardableResult
    func clear(goalID: String) async throws -> GoalSession {
        try await updateStatus(goalID: goalID, to: .cleared)
    }
}

public struct FileGoalSessionStore: GoalSessionListingStore, GoalAtomicSessionStore {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func load(goalID: String) async throws -> GoalSession? {
        try await goalFileAccessCoordinator.load(
            rootURL: rootURL,
            goalID: requireGoalID(goalID)
        )
    }

    public func list() async throws -> [GoalSession] {
        try await goalFileAccessCoordinator.list(rootURL: rootURL)
    }

    public func save(_ session: GoalSession) async throws {
        try await goalFileAccessCoordinator.save(
            session,
            rootURL: rootURL
        )
    }

    public func save(
        _ session: GoalSession,
        replacing expected: GoalSession?
    ) async throws -> Bool {
        try await goalFileAccessCoordinator.compareAndSwap(
            session,
            replacing: expected,
            rootURL: rootURL
        )
    }

    public func path(goalID: String) -> String {
        fileURL(goalID: GoalPath.sanitized(goalID)).path
    }

    public func updateStatus(goalID: String, to status: GoalStatus) async throws -> GoalSession {
        try await goalFileAccessCoordinator.updateStatus(
            rootURL: rootURL,
            goalID: requireGoalID(goalID),
            to: status
        )
    }

    private func fileURL(goalID: String) -> URL {
        goalSessionFileURL(rootURL: rootURL, goalID: goalID)
    }

    private func requireGoalID(_ raw: String) throws -> String {
        let clean = GoalPath.sanitized(raw)
        guard !clean.isEmpty else { throw GoalError.invalidGoalID }
        return clean
    }
}

private let goalFileAccessCoordinator = GoalFileAccessCoordinator()

/// Serializes file-backed goal state within one process, including across
/// independently-created FileGoalSessionStore values that resolve to the
/// same root. This makes compare-and-swap and host status transitions atomic
/// in the process while keeping cross-process coordination host-replaceable.
private actor GoalFileAccessCoordinator {
    func load(rootURL: URL, goalID: String) throws -> GoalSession? {
        let clean = GoalPath.sanitized(goalID)
        let url = fileURL(rootURL: rootURL, goalID: clean)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let session = try JSONDecoder.nativeAgent().decode(
                GoalSession.self,
                from: GoalBoundedFileReader.read(
                    from: url,
                    label: "goal \"\(clean)\""
                )
            )
            try GoalReducer.validate(session)
            return session
        } catch let error as GoalError {
            throw error
        } catch {
            throw GoalError.storeFailure(
                "failed to load goal \"\(clean)\": \(error.localizedDescription)"
            )
        }
    }

    func list(rootURL: URL) throws -> [GoalSession] {
        do {
            guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
            let urls = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let decoder = JSONDecoder.nativeAgent()
            let goalURLs = urls
                .filter { $0.lastPathComponent.hasSuffix(".goal.json") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard goalURLs.count <= GoalResourceLimits.maximumStoredGoals else {
                throw GoalError.storeFailure(
                    "goal store contains \(goalURLs.count) files; limit is \(GoalResourceLimits.maximumStoredGoals)"
                )
            }
            return try goalURLs
                .map { url in
                    let session = try decoder.decode(
                        GoalSession.self,
                        from: GoalBoundedFileReader.read(
                            from: url,
                            label: "goal \"\(url.lastPathComponent)\""
                        )
                    )
                    try GoalReducer.validate(session)
                    return session
                }
        } catch let error as GoalError {
            throw error
        } catch {
            throw GoalError.storeFailure(
                "failed to list goals: \(error.localizedDescription)"
            )
        }
    }

    func save(_ session: GoalSession, rootURL: URL) throws {
        try write(session, rootURL: rootURL)
    }

    func compareAndSwap(
        _ session: GoalSession,
        replacing expected: GoalSession?,
        rootURL: URL
    ) throws -> Bool {
        let current = try load(rootURL: rootURL, goalID: session.goalID)
        guard current == expected else { return false }
        try write(session, rootURL: rootURL)
        return true
    }

    func updateStatus(
        rootURL: URL,
        goalID: String,
        to status: GoalStatus
    ) throws -> GoalSession {
        guard let session = try load(rootURL: rootURL, goalID: goalID) else {
            throw GoalError.goalNotFound(goalID)
        }
        let reduction = try GoalReducer.reduce(.setStatus(status), state: session)
        if reduction.effects.isEmpty == false {
            try write(reduction.session, rootURL: rootURL)
        }
        return reduction.session
    }

    private func write(_ session: GoalSession, rootURL: URL) throws {
        let clean = GoalPath.sanitized(session.goalID)
        do {
            try GoalReducer.validate(session)
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder.nativeAgent(sortedKeys: true)
            encoder.outputFormatting.insert(.prettyPrinted)
            encoder.outputFormatting.insert(.withoutEscapingSlashes)
            let data = try encoder.encode(session)
            guard data.count <= GoalResourceLimits.maximumGoalFileBytes else {
                throw GoalError.storeFailure(
                    "goal \"\(clean)\" encodes to \(data.count) bytes; limit is \(GoalResourceLimits.maximumGoalFileBytes)"
                )
            }
            let url = fileURL(rootURL: rootURL, goalID: clean)
            if FileManager.default.fileExists(atPath: url.path),
               try GoalBoundedFileReader.read(
                    from: url,
                    label: "goal \"\(clean)\""
               ) == data {
                return
            }
            try data.write(to: url, options: .atomic)
        } catch let error as GoalError {
            throw error
        } catch {
            throw GoalError.storeFailure(
                "failed to save goal \"\(clean)\": \(error.localizedDescription)"
            )
        }
    }

    private func fileURL(rootURL: URL, goalID: String) -> URL {
        goalSessionFileURL(rootURL: rootURL, goalID: goalID)
    }
}
