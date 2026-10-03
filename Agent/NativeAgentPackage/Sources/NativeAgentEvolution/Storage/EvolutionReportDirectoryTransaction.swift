import NativeAgentDomain
import Foundation

enum EvolutionReportTransactionPhase: String, Codable, Sendable {
    case prepared
    case previousBackedUp
    case committed
}

enum EvolutionReportTransactionAction: Sendable {
    case previousBackedUp
    case committed
}

struct EvolutionReportTransactionReducer: Sendable {
    func reduce(
        phase: EvolutionReportTransactionPhase,
        action: EvolutionReportTransactionAction
    ) throws -> EvolutionReportTransactionPhase {
        switch (phase, action) {
        case (.prepared, .previousBackedUp):
            return .previousBackedUp
        case (.previousBackedUp, .committed):
            return .committed
        default:
            throw EvolutionError.storeFailure(
                "invalid report transaction transition: \(phase.rawValue) -> \(action)")
        }
    }
}

struct EvolutionReportTransactionJournal: Codable, Sendable, Equatable {
    static let currentVersion = "native-agent.evolution-report-transaction/1"

    let version: String
    let runID: String
    let phase: EvolutionReportTransactionPhase
    let hadPreviousDirectory: Bool

    init(
        version: String = currentVersion,
        runID: String,
        phase: EvolutionReportTransactionPhase,
        hadPreviousDirectory: Bool
    ) {
        self.version = version
        self.runID = runID
        self.phase = phase
        self.hadPreviousDirectory = hadPreviousDirectory
    }

    func applying(
        _ action: EvolutionReportTransactionAction
    ) throws -> EvolutionReportTransactionJournal {
        EvolutionReportTransactionJournal(
            version: version,
            runID: runID,
            phase: try EvolutionReportTransactionReducer().reduce(
                phase: phase,
                action: action
            ),
            hadPreviousDirectory: hadPreviousDirectory
        )
    }
}

struct EvolutionReportTransactionFailure: Error, LocalizedError, Sendable {
    let primaryFailure: String
    let recoveryFailure: String

    var errorDescription: String? {
        "Evolution report transaction failed: \(primaryFailure). Recovery also failed: \(recoveryFailure)"
    }
}

struct EvolutionReportCommittedCleanupFailure: Error, LocalizedError, Sendable {
    let failure: String

    var errorDescription: String? {
        "Evolution report was committed, but transaction cleanup is pending: \(failure)"
    }
}

struct EvolutionReportDirectoryTransaction {
    private static let maximumJournalBytes = 64 * 1_024

    let rootURL: URL
    let fileManager: FileManager

    func perform(_ plan: EvolutionReportStoragePlan) throws {
        let runID = plan.storedReport.runID
        let destination = destinationURL(runID: runID)
        try recoverIfNeeded(runID: runID)

        let transactionRoot = transactionRootURL(runID: runID)
        let staging = stagingURL(runID: runID)
        let backup = backupURL(runID: runID)
        var journal: EvolutionReportTransactionJournal?
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
            try write(plan, to: staging)
            let prepared = EvolutionReportTransactionJournal(
                runID: runID,
                phase: .prepared,
                hadPreviousDirectory: fileManager.fileExists(atPath: destination.path)
            )
            try write(prepared, runID: runID)
            journal = prepared

            if prepared.hadPreviousDirectory {
                try fileManager.moveItem(at: destination, to: backup)
            }
            let backedUp = try prepared.applying(.previousBackedUp)
            try write(backedUp, runID: runID)
            journal = backedUp

            try fileManager.moveItem(at: staging, to: destination)
            let committed = try backedUp.applying(.committed)
            try write(committed, runID: runID)
            journal = committed
        } catch {
            if journal?.phase == .committed {
                throw EvolutionReportCommittedCleanupFailure(failure: error.localizedDescription)
            }
            do {
                try rollback(runID: runID, journal: journal)
            } catch let recoveryError {
                throw EvolutionReportTransactionFailure(
                    primaryFailure: error.localizedDescription,
                    recoveryFailure: recoveryError.localizedDescription
                )
            }
            throw error
        }

        do {
            try removeTransactionRoot(runID: runID)
        } catch {
            throw EvolutionReportCommittedCleanupFailure(failure: error.localizedDescription)
        }
    }

    func recoverIfNeeded(runID: String) throws {
        let transactionRoot = transactionRootURL(runID: runID)
        guard fileManager.fileExists(atPath: transactionRoot.path) else { return }
        let journalFile = journalURL(runID: runID)
        guard fileManager.fileExists(atPath: journalFile.path) else {
            guard !fileManager.fileExists(atPath: backupURL(runID: runID).path) else {
                throw EvolutionError.storeFailure(
                    "evolution report backup exists without a durable transaction journal")
            }
            try removeTransactionRoot(runID: runID)
            return
        }

        let journal = try readJournal(runID: runID)
        switch journal.phase {
        case .prepared:
            try removeTransactionRoot(runID: runID)
        case .previousBackedUp:
            try restorePreviousDirectory(runID: runID, journal: journal)
            try removeTransactionRoot(runID: runID)
        case .committed:
            guard fileManager.fileExists(atPath: destinationURL(runID: runID).path) else {
                throw EvolutionError.storeFailure(
                    "committed evolution report directory is missing")
            }
            try removeTransactionRoot(runID: runID)
        }
    }

    private func write(
        _ plan: EvolutionReportStoragePlan,
        to directory: URL
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder.nativeAgent(sortedKeys: true)
        encoder.outputFormatting.insert(.prettyPrinted)
        encoder.outputFormatting.insert(.withoutEscapingSlashes)

        try encoder.encode(plan.storedReport).write(
            to: directory.appendingPathComponent("report.json"),
            options: .atomic
        )
        try plan.storedReport.source.content.write(
            to: directory.appendingPathComponent("source.txt"),
            atomically: true,
            encoding: .utf8
        )
        let candidatesDirectory = directory.appendingPathComponent("candidates", isDirectory: true)
        try fileManager.createDirectory(at: candidatesDirectory, withIntermediateDirectories: true)
        for (candidateReport, fileName) in zip(
            plan.storedReport.candidates,
            plan.candidateFileNames
        ) {
            try candidateReport.candidate.content.write(
                to: candidatesDirectory.appendingPathComponent(fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        if let proposal = plan.applyProposal {
            try encoder.encode(proposal).write(
                to: directory.appendingPathComponent("apply_proposal.json"),
                options: .atomic
            )
        }
    }

    private func rollback(
        runID: String,
        journal: EvolutionReportTransactionJournal?
    ) throws {
        guard let journal else {
            try removeTransactionRoot(runID: runID)
            return
        }
        switch journal.phase {
        case .prepared:
            try removeTransactionRoot(runID: runID)
        case .previousBackedUp:
            try restorePreviousDirectory(runID: runID, journal: journal)
            try removeTransactionRoot(runID: runID)
        case .committed:
            break
        }
    }

    private func restorePreviousDirectory(
        runID: String,
        journal: EvolutionReportTransactionJournal
    ) throws {
        let destination = destinationURL(runID: runID)
        let backup = backupURL(runID: runID)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if journal.hadPreviousDirectory {
            guard fileManager.fileExists(atPath: backup.path) else {
                throw EvolutionError.storeFailure(
                    "evolution report rollback is missing its previous directory backup")
            }
            try fileManager.moveItem(at: backup, to: destination)
        }
    }

    private func write(
        _ journal: EvolutionReportTransactionJournal,
        runID: String
    ) throws {
        let data = try JSONEncoder.nativeAgent(sortedKeys: true).encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw EvolutionError.storeFailure(
                "evolution report transaction journal exceeds \(Self.maximumJournalBytes) bytes"
            )
        }
        try data.write(
            to: journalURL(runID: runID),
            options: .atomic
        )
    }

    private func readJournal(runID: String) throws -> EvolutionReportTransactionJournal {
        let journal = try JSONDecoder.nativeAgent().decode(
            EvolutionReportTransactionJournal.self,
            from: readJournalData(runID: runID)
        )
        guard journal.version == EvolutionReportTransactionJournal.currentVersion,
                    journal.runID == runID else {
            throw EvolutionError.storeFailure(
                "unsupported or mismatched evolution report transaction journal")
        }
        return journal
    }

    private func readJournalData(runID: String) throws -> Data {
        let url = journalURL(runID: runID)
        let handle = try FileHandle(forReadingFrom: url)
        let operation: Result<Data, any Error>
        do {
            let data = try handle.read(
                upToCount: Self.maximumJournalBytes + 1
            ) ?? Data()
            guard data.count <= Self.maximumJournalBytes else {
                throw EvolutionError.storeFailure(
                    "evolution report transaction journal exceeds \(Self.maximumJournalBytes) bytes"
                )
            }
            operation = .success(data)
        } catch {
            operation = .failure(error)
        }
        let closeError: (any Error)?
        do {
            try handle.close()
            closeError = nil
        } catch {
            closeError = error
        }
        return try OperationCleanupCompletionPolicy.resolve(
            operation: operation,
            cleanupError: closeError
        )
    }

    private func destinationURL(runID: String) -> URL {
        rootURL.appendingPathComponent(EvolutionPath.sanitized(runID), isDirectory: true)
    }

    private func transactionRootURL(runID: String) -> URL {
        rootURL.appendingPathComponent(
            ".\(EvolutionPath.sanitized(runID)).transaction",
            isDirectory: true
        )
    }

    private func stagingURL(runID: String) -> URL {
        transactionRootURL(runID: runID).appendingPathComponent("staged", isDirectory: true)
    }

    private func backupURL(runID: String) -> URL {
        transactionRootURL(runID: runID).appendingPathComponent("backup", isDirectory: true)
    }

    private func journalURL(runID: String) -> URL {
        transactionRootURL(runID: runID).appendingPathComponent("journal.json")
    }

    private func removeTransactionRoot(runID: String) throws {
        let url = transactionRootURL(runID: runID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
