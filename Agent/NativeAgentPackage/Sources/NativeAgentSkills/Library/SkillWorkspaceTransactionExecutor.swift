import NativeAgentDomain
import Foundation

struct SkillWorkspaceTransactionExecutor {
    private let workspace: SkillWorkspace
    private let fileManager: FileManager
    private let pathPolicy: SkillPathPolicy
    private let fileImportPolicy: SkillFileImportPolicy
    private let stateStore: SkillStatePersistenceBoundary
    private let fileRemoval: SkillFileRemoval

    init(
        workspace: SkillWorkspace,
        fileManager: FileManager,
        pathPolicy: SkillPathPolicy,
        fileImportPolicy: SkillFileImportPolicy,
        stateStore: SkillStatePersistenceBoundary,
        fileRemoval: SkillFileRemoval = .foundation
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.pathPolicy = pathPolicy
        self.fileImportPolicy = fileImportPolicy
        self.stateStore = stateStore
        self.fileRemoval = fileRemoval
    }

    nonisolated(nonsending)
    func perform(_ plan: SkillWorkspaceMutationPlan) async throws {
        try await recoverIfNeeded()

        let journal: SkillWorkspaceTransactionJournal
        do {
            journal = try stage(plan)
        } catch {
            do {
                try removeTransactionRootIfPresent()
            } catch let cleanupError {
                throw SkillWorkspaceTransactionFailure(
                    operation: "staging",
                    primaryFailure: error.localizedDescription,
                    recoveryFailure: cleanupError.localizedDescription
                )
            }
            throw error
        }

        var currentJournal = journal
        do {
            try applyDirectories(using: currentJournal)
            currentJournal = try currentJournal.applying(.filesApplied)
            try write(currentJournal)
            let currentState = try await stateStore.load()
            guard currentState == currentJournal.previousState else {
                throw AgentError.persistenceFailure(
                    "Skill state changed after planning; refusing to commit stale filesystem effects")
            }
            try await stateStore.save(currentJournal.updatedState)
        } catch {
            try await rollbackOrThrow(primaryError: error, journal: currentJournal)
            throw error
        }

        do {
            currentJournal = try currentJournal.applying(.stateSaved)
            try write(currentJournal)
            try removeTransactionRootIfPresent()
        } catch {
            throw SkillWorkspaceTransactionCommittedCleanupFailure(
                cleanupFailure: error.localizedDescription)
        }
    }

    nonisolated(nonsending)
    func recoverIfNeeded() async throws {
        guard fileManager.fileExists(atPath: transactionRootURL.path) else { return }
        guard fileManager.fileExists(atPath: journalURL.path) else {
            let backupEntries = try existingEntries(in: backupRootURL)
            guard backupEntries.isEmpty else {
                throw AgentError.persistenceFailure(
                    "Skill workspace transaction backup exists without a durable journal")
            }
            try removeTransactionRootIfPresent()
            return
        }

        let journal = try readJournal()
        let currentState = try await stateStore.load()
        if currentState == journal.updatedState {
            try verifyCommittedDirectories(using: journal)
            try removeTransactionRootIfPresent()
            return
        }
        if currentState == journal.previousState {
            try rollbackDirectories(using: journal)
            try removeTransactionRootIfPresent()
            return
        }
        throw AgentError.persistenceFailure(
            "Skill workspace transaction cannot recover because persisted state matches neither journal revision")
    }

    private var transactionRootURL: URL {
        workspace.userSkillsRootURL.appendingPathComponent(
            ".native-agent-skill-transaction",
            isDirectory: true
        )
    }

    private var stagingRootURL: URL {
        transactionRootURL.appendingPathComponent("staged", isDirectory: true)
    }

    private var backupRootURL: URL {
        transactionRootURL.appendingPathComponent("backup", isDirectory: true)
    }

    private var journalURL: URL {
        transactionRootURL.appendingPathComponent("journal.json", isDirectory: false)
    }

    private func stage(_ plan: SkillWorkspaceMutationPlan) throws
        -> SkillWorkspaceTransactionJournal
    {
        try pathPolicy.validateUserSkillsURL(transactionRootURL)
        if fileManager.fileExists(atPath: transactionRootURL.path) {
            throw AgentError.persistenceFailure(
                "An unrecovered skill workspace transaction already exists")
        }
        try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupRootURL, withIntermediateDirectories: true)

        var operations: [SkillWorkspaceTransactionOperation] = []
        for (index, mutation) in plan.directoryMutations.enumerated() {
            let targetURL = try validatedTargetURL(directoryName: mutation.directoryName)
            let originalDigest = try existingDirectoryDigest(at: targetURL)
            let replacementDigest: String?
            switch mutation.contents {
            case .absent:
                replacementDigest = nil
            case .copied(let sourceDirectory):
                let stagedURL = stagedDirectoryURL(index: index)
                try fileImportPolicy.createOrReplaceDirectory(stagedURL)
                try fileImportPolicy.copySkillDirectory(from: sourceDirectory, to: stagedURL)
                replacementDigest = try fileImportPolicy.directoryDigest(at: stagedURL)
            }
            operations.append(
                SkillWorkspaceTransactionOperation(
                    index: index,
                    directoryName: mutation.directoryName,
                    originalDigest: originalDigest,
                    replacementDigest: replacementDigest
                )
            )
        }

        let journal = SkillWorkspaceTransactionJournal(
            phase: .prepared,
            previousState: plan.previousState,
            updatedState: plan.updatedState,
            operations: operations
        )
        try write(journal)
        return journal
    }

    private func applyDirectories(using journal: SkillWorkspaceTransactionJournal) throws {
        for operation in journal.operations {
            let targetURL = try validatedTargetURL(directoryName: operation.directoryName)
            let currentDigest = try existingDirectoryDigest(at: targetURL)
            guard currentDigest == operation.originalDigest else {
                throw AgentError.persistenceFailure(
                    "Skill directory changed after planning: \(operation.directoryName)")
            }

            if let originalDigest = operation.originalDigest {
                let backupURL = backupDirectoryURL(index: operation.index)
                try fileImportPolicy.createOrReplaceDirectory(backupURL)
                try fileImportPolicy.copySkillDirectory(from: targetURL, to: backupURL)
                guard try fileImportPolicy.directoryDigest(at: backupURL) == originalDigest else {
                    throw AgentError.persistenceFailure(
                        "Skill workspace backup verification failed: \(operation.directoryName)")
                }
                try fileRemoval.removeItem(targetURL, fileManager)
            }

            if let replacementDigest = operation.replacementDigest {
                let stagedURL = stagedDirectoryURL(index: operation.index)
                try fileImportPolicy.createOrReplaceDirectory(targetURL)
                try fileImportPolicy.copySkillDirectory(from: stagedURL, to: targetURL)
                guard try fileImportPolicy.directoryDigest(at: targetURL) == replacementDigest else {
                    throw AgentError.persistenceFailure(
                        "Skill workspace replacement verification failed: \(operation.directoryName)")
                }
            }
        }
    }

    nonisolated(nonsending)
    private func rollbackOrThrow(
        primaryError: any Error,
        journal: SkillWorkspaceTransactionJournal
    ) async throws {
        do {
            try rollbackDirectories(using: journal)
            let currentState = try await stateStore.load()
            if currentState == journal.updatedState {
                try await stateStore.save(journal.previousState)
            } else if currentState != journal.previousState {
                throw AgentError.persistenceFailure(
                    "Skill workspace rollback found an unrelated persisted state revision")
            }
            try removeTransactionRootIfPresent()
        } catch let recoveryError {
            throw SkillWorkspaceTransactionFailure(
                operation: journal.phase.rawValue,
                primaryFailure: primaryError.localizedDescription,
                recoveryFailure: recoveryError.localizedDescription
            )
        }
    }

    private func rollbackDirectories(using journal: SkillWorkspaceTransactionJournal) throws {
        for operation in journal.operations.reversed() {
            let targetURL = try validatedTargetURL(directoryName: operation.directoryName)
            let backupURL = backupDirectoryURL(index: operation.index)
            if let originalDigest = operation.originalDigest {
                if try existingDirectoryDigest(at: targetURL) == originalDigest {
                    continue
                }
                guard fileManager.fileExists(atPath: backupURL.path) else {
                    throw AgentError.persistenceFailure(
                        "Skill workspace rollback is missing its original directory backup: \(operation.directoryName)")
                }
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileRemoval.removeItem(targetURL, fileManager)
                }
                try fileImportPolicy.createOrReplaceDirectory(targetURL)
                try fileImportPolicy.copySkillDirectory(from: backupURL, to: targetURL)
                guard try fileImportPolicy.directoryDigest(at: targetURL) == originalDigest else {
                    throw AgentError.persistenceFailure(
                        "Skill workspace rollback verification failed: \(operation.directoryName)")
                }
            } else if fileManager.fileExists(atPath: targetURL.path) {
                try fileRemoval.removeItem(targetURL, fileManager)
            }
        }
    }

    private func verifyCommittedDirectories(
        using journal: SkillWorkspaceTransactionJournal
    ) throws {
        for operation in journal.operations {
            let targetURL = try validatedTargetURL(directoryName: operation.directoryName)
            guard try existingDirectoryDigest(at: targetURL) == operation.replacementDigest else {
                throw AgentError.persistenceFailure(
                    "Committed skill directory does not match its durable receipt: \(operation.directoryName)")
            }
        }
    }

    private func existingDirectoryDigest(at url: URL) throws -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard isDirectory.boolValue else {
            throw AgentError.persistenceFailure("Expected a skill directory at \(url.path)")
        }
        return try fileImportPolicy.directoryDigest(at: url)
    }

    private func validatedTargetURL(directoryName: String) throws -> URL {
        let url = workspace.userSkillDirectoryURL(named: directoryName).standardizedFileURL
        try pathPolicy.validateUserSkillsURL(url)
        guard url.deletingLastPathComponent() == workspace.userSkillsRootURL.standardizedFileURL else {
            throw AgentError.pathOutsideSandbox(directoryName)
        }
        guard url != transactionRootURL.standardizedFileURL else {
            throw AgentError.pathOutsideSandbox(directoryName)
        }
        return url
    }

    private func stagedDirectoryURL(index: Int) -> URL {
        stagingRootURL.appendingPathComponent(String(format: "%06d", index), isDirectory: true)
    }

    private func backupDirectoryURL(index: Int) -> URL {
        backupRootURL.appendingPathComponent(String(format: "%06d", index), isDirectory: true)
    }

    private func write(_ journal: SkillWorkspaceTransactionJournal) throws {
        let data = try JSONEncoder.nativeAgent().encode(journal)
        guard data.count <= SkillLocalFileLimits.maximumJournalBytes else {
            throw AgentError.budgetExceeded(
                "Skill workspace transaction journal exceeds " +
                    "\(SkillLocalFileLimits.maximumJournalBytes) bytes."
            )
        }
        try data.write(to: journalURL, options: .atomic)
    }

    private func readJournal() throws -> SkillWorkspaceTransactionJournal {
        let journal = try JSONDecoder.nativeAgent().decode(
            SkillWorkspaceTransactionJournal.self,
            from: SkillBoundedFileReader.read(
                from: journalURL,
                maximumByteCount: SkillLocalFileLimits.maximumJournalBytes,
                label: "Skill workspace transaction journal"
            )
        )
        guard journal.version == SkillWorkspaceTransactionJournal.currentVersion else {
            throw AgentError.persistenceFailure(
                "Unsupported skill workspace transaction journal: \(journal.version)")
        }
        return journal
    }


    private func existingEntries(in directoryURL: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private func removeTransactionRootIfPresent() throws {
        if fileManager.fileExists(atPath: transactionRootURL.path) {
            try fileManager.removeItem(at: transactionRootURL)
        }
    }
}
