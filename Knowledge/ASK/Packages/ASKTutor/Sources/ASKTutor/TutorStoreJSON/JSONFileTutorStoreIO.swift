import Foundation
import EvidenceIndex
import PageIndex

package struct JSONFileTutorStoreIO {
    package let layout: TutorStoreLayout
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let hooks: JSONFileTutorStoreHooks

    package init(layout: TutorStoreLayout, hooks: JSONFileTutorStoreHooks) {
        self.layout = layout
        self.encoder = JSONEncoderFactory.makeEncoder(prettyPrinted: true)
        self.decoder = JSONDecoder()
        self.hooks = hooks
    }

    package func ensureRoot() throws {
        try createDirectory(layout.rootURL)
        try createDirectory(transactionsDirectoryURL)
        try recoverTransactions()
        try createDirectory(layout.profilesDirectoryURL)
        try createDirectory(layout.sessionsDirectoryURL)
        try createDirectory(layout.practiceDirectoryURL)
        try createDirectory(layout.plansDirectoryURL)
    }

    package func jsonFiles(in directory: URL) throws -> [URL] {
        let validatedDirectory = try validatedStoreURL(directory)
        do {
            return try FileManager.default.contentsOfDirectory(
                at: validatedDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
    }

    package func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: validatedStoreURL(url), withIntermediateDirectories: true)
    }

    package func load<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        let validatedURL = try validatedStoreURL(url)
        do {
            let data = try Data(contentsOf: validatedURL)
            return try decoder.decode(T.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    package func save<T: Encodable>(_ value: T, to url: URL) throws {
        let validatedURL = try validatedStoreURL(url)
        try createDirectory(validatedURL.deletingLastPathComponent())
        let data = try encoder.encode(value)
        try data.write(to: validatedURL, options: .atomic)
    }

    package func writeArchive(_ archive: TutorDataArchive, to url: URL) throws {
        let data = try encoder.encode(archive)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    package func readArchive(from url: URL) throws -> TutorDataArchive {
        let data = try Data(contentsOf: url)
        return try decoder.decode(TutorDataArchive.self, from: data)
    }

    package func makeWrite<T: Encodable>(_ value: T, to url: URL) throws -> JSONFileTutorStoreStagedWrite {
        let target = try validatedStoreURL(url)
        return JSONFileTutorStoreStagedWrite(target: target, data: try encoder.encode(value))
    }

    package func ensureUniqueTargets(_ writes: [JSONFileTutorStoreStagedWrite]) throws {
        let grouped = Dictionary(grouping: writes) { $0.target.path }
        if let duplicate = grouped.first(where: { $0.value.count > 1 })?.key {
            throw ASKTutorError.storage("duplicate batch target `\(duplicate)`")
        }
    }

    package func commitBatch(_ writes: [JSONFileTutorStoreStagedWrite]) throws {
        // A previous committed transaction may only have failed to remove its
        // housekeeping artifacts. Recover it before starting another batch so
        // callers never accumulate ambiguous transaction state in one actor.
        try recoverTransactions()

        let transactionID = UUID().uuidString.lowercased()
        let transactionDirectory = try validatedStoreURL(
            transactionsDirectoryURL.appendingPathComponent(
                JSONFileTutorTransactionContract.directoryPrefix + transactionID,
                isDirectory: true
            )
        )
        do {
            try createDirectory(transactionDirectory)
        } catch {
            let setupError = error
            do {
                try removeItemIfPresent(at: transactionDirectory)
            } catch {
                throw ASKTutorError.storage(
                    "batch staging failed: \(setupError); transaction cleanup failed: \(error)"
                )
            }
            throw ASKTutorError.storage("batch staging failed: \(setupError)")
        }

        var plans: [JSONFileTutorStoreCommitPlan] = []
        do {
            for (index, write) in writes.enumerated() {
                let stagedURL = transactionDirectory.appendingPathComponent("write-\(index).json")
                try write.data.write(to: stagedURL, options: .atomic)
                let hadExistingFile = FileManager.default.fileExists(atPath: write.target.path)
                let backupURL = hadExistingFile
                    ? write.target.deletingLastPathComponent().appendingPathComponent(
                        ".txn-\(transactionID)-\(index)-\(write.target.lastPathComponent).bak"
                    )
                    : nil
                plans.append(
                    JSONFileTutorStoreCommitPlan(
                        target: write.target,
                        stagedURL: stagedURL,
                        backupURL: backupURL,
                        hadExistingFile: hadExistingFile
                    )
                )
            }
        } catch {
            let stagingError = error
            do {
                try removeItemIfPresent(at: transactionDirectory)
            } catch {
                throw ASKTutorError.storage(
                    "batch staging failed: \(stagingError); transaction cleanup failed: \(error)"
                )
            }
            throw ASKTutorError.storage("batch staging failed: \(stagingError)")
        }

        var manifest = try makeTransactionManifest(
            transactionID: transactionID,
            phase: .prepared,
            plans: plans
        )
        try writeTransactionManifest(manifest, in: transactionDirectory)
        manifest.phase = .committing
        try writeTransactionManifest(manifest, in: transactionDirectory)

        var committed: [JSONFileTutorStoreCommitPlan] = []
        do {
            for (index, plan) in plans.enumerated() {
                try createDirectory(plan.target.deletingLastPathComponent())
                try hooks.beforeCommit(plan.target, index)
                if let backupURL = plan.backupURL {
                    try FileManager.default.moveItem(at: plan.target, to: backupURL)
                    do {
                        try FileManager.default.moveItem(at: plan.stagedURL, to: plan.target)
                    } catch {
                        let commitError = error
                        do {
                            try FileManager.default.moveItem(at: backupURL, to: plan.target)
                        } catch {
                            committed.append(plan)
                            throw ASKTutorError.storage(
                                "batch commit failed before target replacement: \(commitError); "
                                    + "backup restoration failed: \(error)"
                            )
                        }
                        throw commitError
                    }
                    committed.append(plan)
                } else {
                    try FileManager.default.moveItem(at: plan.stagedURL, to: plan.target)
                    committed.append(plan)
                }
                try hooks.afterCommit(plan.target, index)
            }
        } catch {
            let commitError = error
            let rollback = rollbackCommittedPlans(committed)

            // If rollback could not restore every target, keep the durable
            // manifest and retained backups. A later reopen can retry recovery
            // instead of losing the only description of the interrupted batch.
            if !rollback.failures.isEmpty {
                var recoveryFailures = ["rollback: \(rollback.failures.joined(separator: "; "))"]
                do {
                    try cleanupBackups(in: plans, preserving: rollback.retainedBackups)
                } catch {
                    recoveryFailures.append("backup cleanup: \(error)")
                }
                throw ASKTutorError.storage(
                    "batch commit failed: \(commitError); recovery pending: "
                        + recoveryFailures.joined(separator: "; ")
                )
            }

            // The domain write is fully rolled back. Housekeeping failures leave
            // the manifest in place so the next reopen/commit can finish cleanup.
            do {
                try cleanupBackups(in: plans)
                try removeItemIfPresent(at: transactionDirectory)
            } catch {
                throw ASKTutorError.storage(
                    "batch commit failed: \(commitError); rollback completed; cleanup pending: \(error)"
                )
            }
            throw ASKTutorError.storage("batch commit failed: \(commitError)")
        }

        manifest.phase = .committed
        do {
            try writeTransactionManifest(manifest, in: transactionDirectory)
        } catch {
            let commitError = error
            let rollback = rollbackCommittedPlans(committed)
            guard rollback.failures.isEmpty else {
                throw ASKTutorError.storage(
                    "batch commit finalization failed: \(commitError); recovery pending: rollback: "
                        + rollback.failures.joined(separator: "; ")
                )
            }
            do {
                try cleanupBackups(in: plans)
                try removeItemIfPresent(at: transactionDirectory)
            } catch {
                throw ASKTutorError.storage(
                    "batch commit finalization failed: \(commitError); rollback completed; "
                        + "cleanup pending: \(error)"
                )
            }
            throw ASKTutorError.storage("batch commit finalization failed: \(commitError)")
        }

        var cleanupFailures: [String] = []
        do {
            try cleanupBackups(in: plans)
        } catch {
            cleanupFailures.append("backup cleanup: \(error)")
        }
        do {
            try removeItemIfPresent(at: transactionDirectory)
        } catch {
            cleanupFailures.append("transaction cleanup: \(error)")
        }
        if !cleanupFailures.isEmpty {
            throw TutorStorePostCommitError(
                transactionID: transactionID,
                cause: cleanupFailures.joined(separator: "; ")
            )
        }
    }

    private var transactionsDirectoryURL: URL {
        layout.rootURL.appendingPathComponent(".transactions", isDirectory: true)
    }

    private func recoverTransactions() throws {
        let directory = try validatedStoreURL(transactionsDirectoryURL)
        let transactionURLs: [URL]
        do {
            transactionURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }

        for listedTransactionURL in transactionURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // FileManager may return a symlink-canonical path (for example,
            // /private/var) even when the configured root uses its alias (/var).
            // Normalize the enumerated URL before deriving child paths so the
            // store-root containment check sees a consistent path spelling.
            let transactionURL = listedTransactionURL.standardizedFileURL
            let values = try transactionURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            try recoverTransaction(at: transactionURL)
        }
    }

    private func recoverTransaction(at transactionDirectory: URL) throws {
        let manifestURL = transactionDirectory.appendingPathComponent(
            JSONFileTutorTransactionContract.manifestFilename
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            // Current transaction directories use an explicit version prefix.
            // No target mutation is allowed before the manifest exists, so a
            // prefix-matching directory without a manifest is staging-only and
            // can be discarded. Unversioned/unknown directories fail closed.
            if transactionDirectory.lastPathComponent.hasPrefix(
                JSONFileTutorTransactionContract.directoryPrefix
            ) {
                try removeItemIfPresent(at: transactionDirectory)
                return
            }
            throw ASKTutorError.storage(
                "incomplete tutor transaction has no recovery manifest: \(transactionDirectory.lastPathComponent)"
            )
        }

        let manifest: JSONFileTutorTransactionManifest
        do {
            manifest = try decoder.decode(
                JSONFileTutorTransactionManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw ASKTutorError.storage(
                "unable to decode tutor transaction manifest `\(transactionDirectory.lastPathComponent)`: \(error)"
            )
        }
        guard manifest.schemaVersion == JSONFileTutorTransactionContract.schemaVersion else {
            throw ASKTutorError.storage(
                "unsupported tutor transaction manifest version \(manifest.schemaVersion)"
            )
        }

        let plans = try manifest.plans.map { try recoveryPlan(from: $0, transactionDirectory: transactionDirectory) }
        switch manifest.phase {
        case .committed:
            try cleanupBackups(in: plans)
            try removeItemIfPresent(at: transactionDirectory)
        case .prepared, .committing:
            let rollback = rollbackInterruptedPlans(plans)
            guard rollback.failures.isEmpty else {
                throw ASKTutorError.storage(
                    "tutor transaction recovery failed: " + rollback.failures.joined(separator: "; ")
                )
            }
            try cleanupBackups(in: plans, preserving: rollback.retainedBackups)
            try removeItemIfPresent(at: transactionDirectory)
        }
    }

    private func rollbackInterruptedPlans(
        _ plans: [JSONFileTutorStoreCommitPlan]
    ) -> (failures: [String], retainedBackups: Set<String>) {
        var failures: [String] = []
        var retainedBackups: Set<String> = []

        for plan in plans.reversed() {
            do {
                let stagedExists = FileManager.default.fileExists(atPath: plan.stagedURL.path)
                let targetExists = FileManager.default.fileExists(atPath: plan.target.path)
                let backupExists = plan.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

                if let backupURL = plan.backupURL, backupExists {
                    try removeItemIfPresent(at: plan.target)
                    try FileManager.default.moveItem(at: backupURL, to: plan.target)
                    continue
                }

                if plan.hadExistingFile {
                    // With no backup, two states are valid while the manifest is still
                    // `committing`: (1) the original target was never replaced and the
                    // staged file remains, or (2) an in-process finalization failure
                    // already rolled the replacement back and consumed the staged file.
                    // In both cases the existing target is the pre-transaction value.
                    guard targetExists else {
                        throw ASKTutorError.storage(
                            "cannot recover existing target `\(plan.target.path)` without its backup"
                        )
                    }
                } else if !stagedExists && targetExists {
                    // The staged file was moved into a target that did not exist before the transaction.
                    try removeItemIfPresent(at: plan.target)
                } else if stagedExists && targetExists {
                    throw ASKTutorError.storage(
                        "new transaction target appeared before commit `\(plan.target.path)`"
                    )
                }
            } catch {
                failures.append("\(plan.target.path): \(error)")
                if let backupURL = plan.backupURL,
                   FileManager.default.fileExists(atPath: backupURL.path) {
                    retainedBackups.insert(backupURL.path)
                }
            }
        }
        return (failures, retainedBackups)
    }

    private func makeTransactionManifest(
        transactionID: String,
        phase: JSONFileTutorTransactionPhase,
        plans: [JSONFileTutorStoreCommitPlan]
    ) throws -> JSONFileTutorTransactionManifest {
        JSONFileTutorTransactionManifest(
            schemaVersion: JSONFileTutorTransactionContract.schemaVersion,
            transactionID: transactionID,
            phase: phase,
            plans: try plans.map { plan in
                JSONFileTutorTransactionManifest.Plan(
                    targetRelativePath: try relativeStorePath(for: plan.target),
                    stagedFilename: plan.stagedURL.lastPathComponent,
                    backupRelativePath: try plan.backupURL.map(relativeStorePath(for:)),
                    hadExistingFile: plan.hadExistingFile
                )
            }
        )
    }

    private func writeTransactionManifest(
        _ manifest: JSONFileTutorTransactionManifest,
        in transactionDirectory: URL
    ) throws {
        let manifestURL = try validatedStoreURL(
            transactionDirectory.appendingPathComponent(
                JSONFileTutorTransactionContract.manifestFilename,
                isDirectory: false
            )
        )
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private func recoveryPlan(
        from plan: JSONFileTutorTransactionManifest.Plan,
        transactionDirectory: URL
    ) throws -> JSONFileTutorStoreCommitPlan {
        let target = try storeURL(forRelativePath: plan.targetRelativePath)
        let stagedURL = try validatedStoreURL(
            transactionDirectory.appendingPathComponent(plan.stagedFilename, isDirectory: false)
        )
        let backupURL = try plan.backupRelativePath.map(storeURL(forRelativePath:))
        return JSONFileTutorStoreCommitPlan(
            target: target,
            stagedURL: stagedURL,
            backupURL: backupURL,
            hadExistingFile: plan.hadExistingFile
        )
    }

    private func relativeStorePath(for url: URL) throws -> String {
        let candidate = try validatedStoreURL(url)
        let root = layout.rootURL.standardizedFileURL.path
        let path = candidate.path
        if path == root { return "" }
        return String(path.dropFirst(root.count + 1))
    }

    private func storeURL(forRelativePath relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw ASKTutorError.storage("invalid transaction relative path")
        }
        return try validatedStoreURL(
            layout.rootURL.appendingPathComponent(relativePath, isDirectory: false)
        )
    }

    package func validatedStoreURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        let rootURL = layout.rootURL.standardizedFileURL
        let rootPath = rootURL.path
        let candidatePath = candidate.path
        let isInsideRoot = candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        guard isInsideRoot else {
            throw ASKTutorError.invalidInput("store path escapes tutor root")
        }
        return candidate
    }

    private func rollbackCommittedPlans(
        _ committed: [JSONFileTutorStoreCommitPlan]
    ) -> (failures: [String], retainedBackups: Set<String>) {
        var failures: [String] = []
        var retainedBackups: Set<String> = []
        for plan in committed.reversed() {
            do {
                if let backupURL = plan.backupURL {
                    try removeItemIfPresent(at: plan.target)
                    try FileManager.default.moveItem(at: backupURL, to: plan.target)
                } else if !plan.hadExistingFile {
                    try removeItemIfPresent(at: plan.target)
                }
            } catch {
                failures.append("\(plan.target.path): \(error)")
                if let backupURL = plan.backupURL {
                    retainedBackups.insert(backupURL.path)
                }
            }
        }
        return (failures, retainedBackups)
    }

    private func cleanupBackups(
        in plans: [JSONFileTutorStoreCommitPlan],
        preserving retainedBackups: Set<String> = []
    ) throws {
        var failures: [String] = []
        for plan in plans {
            guard let backupURL = plan.backupURL else { continue }
            guard !retainedBackups.contains(backupURL.path) else { continue }
            do {
                try removeItemIfPresent(at: backupURL)
            } catch {
                failures.append("\(backupURL.path): \(error)")
            }
        }
        guard failures.isEmpty else {
            throw ASKTutorError.storage(failures.joined(separator: "; "))
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

}

private enum JSONFileTutorTransactionContract {
    static let schemaVersion = 1
    static let directoryPrefix = "v1-"
    static let manifestFilename = "manifest.json"
}

private enum JSONFileTutorTransactionPhase: String, Codable, Sendable {
    case prepared
    case committing
    case committed
}

private struct JSONFileTutorTransactionManifest: Codable, Sendable {
    struct Plan: Codable, Sendable {
        let targetRelativePath: String
        let stagedFilename: String
        let backupRelativePath: String?
        let hadExistingFile: Bool
    }

    let schemaVersion: Int
    let transactionID: String
    var phase: JSONFileTutorTransactionPhase
    let plans: [Plan]
}

package struct JSONFileTutorStoreStagedWrite {
    package let target: URL
    package let data: Data
}

private struct JSONFileTutorStoreCommitPlan {
    let target: URL
    let stagedURL: URL
    let backupURL: URL?
    let hadExistingFile: Bool
}
