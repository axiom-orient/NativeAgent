import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import KnowledgeCore

extension Vault {
    private struct JournalSnapshot {
        let store: KnowledgeStore
        let report: RebuildReport
    }


    /// Replay order of a journal entry: decision time, then plan time, then patch ID.
    /// Times are ordered chronologically, not lexicographically, so a receipt
    /// written with a UTC offset replays at the instant it actually happened.
    private struct JournalOrderKey: Comparable {
        let decidedAt: ASKTimestamp.OrderKey
        let generatedAt: ASKTimestamp.OrderKey
        let patchID: String

        init(decidedAt: String, generatedAt: String, patchID: String) {
            self.decidedAt = ASKTimestamp.OrderKey(decidedAt)
            self.generatedAt = ASKTimestamp.OrderKey(generatedAt)
            self.patchID = patchID
        }

        static func < (lhs: JournalOrderKey, rhs: JournalOrderKey) -> Bool {
            if lhs.decidedAt != rhs.decidedAt { return lhs.decidedAt < rhs.decidedAt }
            if lhs.generatedAt != rhs.generatedAt { return lhs.generatedAt < rhs.generatedAt }
            return lhs.patchID < rhs.patchID
        }
    }

    /// Checks that an approved patch's raw evidence is present and unmodified.
    ///
    /// This reads and digests every raw file the patch refers to, so it runs when
    /// a decision is made — not when state is loaded. Replaying the journal used
    /// to call it for every approved patch, which made loading state cost as much
    /// as the total captured bytes; `verifyRawEvidence()` re-checks the whole
    /// vault on demand instead.
    package func ensureRawInputsForPlan(_ plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) throws {
        if receipt.decision != .approved { return }
        for source in plan.sourceReceipts {
            let rawURL = root.appendingPathComponent(source.rawRelpath)
            guard FileManager.default.fileExists(atPath: rawURL.path) else {
                throw ASKError.apply(
                    "approved patch requires raw evidence at `\(source.rawRelpath)`; missing raw capture. collector outputRoot must match the vault root passed to apply"
                )
            }
            guard isVerifiableSHA256(source.contentHash) else {
                throw ASKError.apply(
                    "approved patch raw evidence must carry a verifiable SHA-256 hash at `\(source.rawRelpath)`"
                )
            }
            let bytes = try Data(contentsOf: rawURL)
            let actualHash = sha256Prefixed(bytes)
            if actualHash != source.contentHash {
                throw ASKError.apply(
                    "approved patch raw evidence hash mismatch at `\(source.rawRelpath)`; expected \(source.contentHash) but found \(actualHash)"
                )
            }
        }
    }

    private func isVerifiableSHA256(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        guard digest.count == 64 else { return false }
        return digest.unicodeScalars.allSatisfy { scalar in
            (48 ... 57).contains(scalar.value) || (97 ... 102).contains(scalar.value)
        }
    }

    package func persistJournalFile<T: Encodable>(_ url: URL, payload: T) throws {
        let validatedURL = try validatedVaultURL(url)
        let encoded = try CanonicalJSON.data(for: payload) + Data([0x0a])
        try FileManager.default.createDirectory(at: validatedURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        if FileManager.default.fileExists(atPath: validatedURL.path) {
            let existing = try Data(contentsOf: validatedURL)
            if existing != encoded {
                throw ASKError.journalConflict("journal conflict at `\(validatedURL.path)`")
            }
            return
        }
        try encoded.write(to: validatedURL, options: .atomic)
    }

    private func syncFile(at url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw ASKError.apply("unable to open journal file for sync: `\(url.path)`")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ASKError.apply("unable to sync journal file: `\(url.path)`")
        }
    }

    private func syncDirectory(at url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw ASKError.apply("unable to open journal directory for sync: `\(url.path)`")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ASKError.apply("unable to sync journal directory: `\(url.path)`")
        }
    }

    /// Publishes a new patch directory only after all required files are complete.
    /// Existing pending patches keep their stable directory and receive the receipt
    /// as one atomic file write.
    private func publishPatchEntry(
        plan: KnowledgePatchPlan,
        receipt: PatchDecisionReceipt?
    ) throws {
        let fileManager = FileManager.default
        let patchDir = try validatedVaultURL(patchDirectory(plan.patchID))
        if fileManager.fileExists(atPath: patchDir.path) {
            let patchURL = patchDir.appendingPathComponent("patch.json")
            guard fileManager.fileExists(atPath: patchURL.path) else {
                throw ASKError.journalConflict("journal patch directory is incomplete: `\(plan.patchID)`")
            }
            let existing = try CanonicalJSON.load(KnowledgePatchPlan.self, from: patchURL)
            guard existing == plan else {
                throw ASKError.journalConflict("journal conflict for patch `\(plan.patchID)`")
            }
            if let receipt {
                let receiptURL = patchDir.appendingPathComponent("receipt.json")
                try persistJournalFile(receiptURL, payload: receipt)
                try syncFile(at: receiptURL)
                try syncDirectory(at: patchDir)
            }
            return
        }

        let patchesRoot = try validatedVaultURL(patchDir.deletingLastPathComponent())
        try fileManager.createDirectory(at: patchesRoot, withIntermediateDirectories: true)
        let staging = patchesRoot.appendingPathComponent(".staging-\(plan.patchID)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let patchURL = staging.appendingPathComponent("patch.json")
            try persistJournalFile(patchURL, payload: plan)
            try syncFile(at: patchURL)
            if let receipt {
                let receiptURL = staging.appendingPathComponent("receipt.json")
                try persistJournalFile(receiptURL, payload: receipt)
                try syncFile(at: receiptURL)
            }
            try fileManager.moveItem(at: staging, to: patchDir)
            try syncDirectory(at: patchesRoot)
        } catch {
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: patchDir.path) {
                let patchURL = patchDir.appendingPathComponent("patch.json")
                if let existing = try? CanonicalJSON.load(KnowledgePatchPlan.self, from: patchURL), existing == plan {
                    if let receipt {
                        let receiptURL = patchDir.appendingPathComponent("receipt.json")
                        try persistJournalFile(receiptURL, payload: receipt)
                        try syncFile(at: receiptURL)
                        try syncDirectory(at: patchDir)
                    }
                    return
                }
            }
            throw error
        }
    }

    package func recordEvent(_ entry: OperationLogEntry) throws {
        try bootstrap()
        try entry.validate()
        let url = try validatedVaultURL(eventURL(entry.logID))
        if FileManager.default.fileExists(atPath: url.path) {
            let existing: OperationLogEntry
            do {
                existing = try CanonicalJSON.load(OperationLogEntry.self, from: url)
            } catch {
                throw ASKError.journalConflict("journal event at `\(url.path)` is not a valid operation log")
            }
            guard existing == entry else {
                throw ASKError.journalConflict("journal conflict at `\(url.path)`")
            }
            return
        }
        try persistJournalFile(url, payload: entry)
    }

    package func stage(_ plan: KnowledgePatchPlan) throws {
        try withMaterializeLock {
            try plan.validate()
            try publishPatchEntry(plan: plan, receipt: nil)
        }
    }

    package func apply(_ plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt) throws -> ApplyResult {
        try withMaterializeLock {
            try bootstrap()
            let existingSnapshot = try loadJournalSnapshot()
            return try applyUnlocked(plan, receipt: receipt, existingSnapshot: existingSnapshot)
        }
    }

    package func applyFromCurrentJournal(
        _ buildDecision: (KnowledgeStore) throws -> (plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)
    ) throws -> ApplyResult {
        try withMaterializeLock {
            try bootstrap()
            let existingSnapshot = try loadJournalSnapshot()
            let decision = try buildDecision(existingSnapshot.store)
            return try applyUnlocked(decision.plan, receipt: decision.receipt, existingSnapshot: existingSnapshot)
        }
    }

    package func loadStoreFromJournal() throws -> (store: KnowledgeStore, report: RebuildReport) {
        let snapshot = try loadJournalSnapshot()
        return (snapshot.store, snapshot.report)
    }

    private func loadJournalSnapshot() throws -> JournalSnapshot {
        // A matching cache key does not authenticate the checkpoint's contents.
        // Canonical reads and commit validation always use the same journal fold.
        // This path does not repair or rewrite derived files.
        return try replayJournal()
    }


    private func emptyJournalSnapshot() throws -> JournalSnapshot {
        var store = KnowledgeStore.openInMemory()
        try store.rebuildSearchIndex()
        return JournalSnapshot(
            store: store,
            report: RebuildReport(
                approvedPatchIDs: [],
                rejectedPatchIDs: [],
                pendingPatchIDs: [],
                mirrorCounts: [:]
            )
        )
    }

    /// The same fold validates a candidate before publication and rebuilds the
    /// durable journal. A candidate replaces only an identical pending plan.
    private func replayJournal(
        candidate: (plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)? = nil
    ) throws -> JournalSnapshot {
        var store = KnowledgeStore.openInMemory()
        let fileManager = FileManager.default

        // Reads must not bootstrap a missing vault. Mutation paths call bootstrap()
        // before reaching this function, while a missing read-only vault represents
        // an empty canonical state and must remain side-effect free.
        guard fileManager.fileExists(atPath: root.path) else {
            return try emptyJournalSnapshot()
        }

        let journalRoot = root.appendingPathComponent(".ask/journal/patches", isDirectory: true)
        var entries: [(JournalOrderKey, KnowledgePatchPlan, PatchDecisionReceipt?)] = []

        let patchURLs: [URL]
        var patchesIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: journalRoot.path, isDirectory: &patchesIsDirectory) {
            guard patchesIsDirectory.boolValue else {
                throw ASKError.journalConflict("journal patches path is not a directory: `\(journalRoot.path)`")
            }
            patchURLs = try fileManager.contentsOfDirectory(
                at: journalRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } else {
            patchURLs = []
        }
        let patchDirs = try patchURLs
            .filter { url in
                if url.lastPathComponent.hasPrefix(".") { return false }
                return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for patchDir in patchDirs {
            let patchURL = patchDir.appendingPathComponent("patch.json")
            guard FileManager.default.fileExists(atPath: patchURL.path) else {
                throw ASKError.journalConflict(
                    "journal patch directory is missing patch.json: `\(patchDir.lastPathComponent)`"
                )
            }
            let plan = try CanonicalJSON.load(KnowledgePatchPlan.self, from: patchURL)
            try plan.validate()
            let receiptURL = patchDir.appendingPathComponent("receipt.json")
            let receipt: PatchDecisionReceipt?
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                let loaded = try CanonicalJSON.load(PatchDecisionReceipt.self, from: receiptURL)
                try loaded.validate()
                receipt = loaded
            } else {
                receipt = nil
            }
            let decisionAt = receipt?.decidedAt ?? ASKTimestamp.openEndedSentinel
            entries.append((
                JournalOrderKey(decidedAt: decisionAt, generatedAt: plan.generatedAt, patchID: plan.patchID),
                plan,
                receipt
            ))
        }

        if let candidate {
            if let index = entries.firstIndex(where: { $0.1.patchID == candidate.plan.patchID }) {
                let existing = entries[index]
                guard existing.1 == candidate.plan,
                      existing.2 == nil || existing.2 == candidate.receipt else {
                    throw ASKError.journalConflict("journal conflict for patch `\(candidate.plan.patchID)`")
                }
                entries.remove(at: index)
            }
            entries.append((
                JournalOrderKey(
                    decidedAt: candidate.receipt.decidedAt,
                    generatedAt: candidate.plan.generatedAt,
                    patchID: candidate.plan.patchID
                ), candidate.plan, candidate.receipt
            ))
        }
        entries.sort { $0.0 < $1.0 }

        var approvedPatchIDs: [String] = []
        var rejectedPatchIDs: [String] = []
        var pendingPatchIDs: [String] = []

        for (_, plan, receipt) in entries {
            let patchID = plan.patchID
            try store.putPatchPlan(plan)
            guard let receipt else {
                pendingPatchIDs.append(patchID)
                continue
            }
            try store.applyPatchReceipt(plan: plan, receipt: receipt)
            if receipt.decision == .approved {
                approvedPatchIDs.append(patchID)
            } else {
                rejectedPatchIDs.append(patchID)
            }
        }

        let eventsRoot = root.appendingPathComponent(".ask/journal/events", isDirectory: true)
        let eventURLs: [URL]
        var eventsIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: eventsRoot.path, isDirectory: &eventsIsDirectory) {
            guard eventsIsDirectory.boolValue else {
                throw ASKError.journalConflict("journal events path is not a directory: `\(eventsRoot.path)`")
            }
            eventURLs = try fileManager.contentsOfDirectory(
                at: eventsRoot,
                includingPropertiesForKeys: nil
            )
        } else {
            eventURLs = []
        }
        let sortedEventURLs = eventURLs
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var eventEntries: [OperationLogEntry] = []
        for url in sortedEventURLs {
            let entry = try CanonicalJSON.load(OperationLogEntry.self, from: url)
            try entry.validate()
            eventEntries.append(entry)
        }
        eventEntries = OperationLogEntry.canonicallyOrdered(eventEntries)
        for entry in eventEntries {
            try store.putOperationLog(entry)
        }

        try store.rebuildSearchIndex()

        let report = RebuildReport(
            approvedPatchIDs: approvedPatchIDs,
            rejectedPatchIDs: rejectedPatchIDs,
            pendingPatchIDs: pendingPatchIDs,
            mirrorCounts: [:]
        )
        return JournalSnapshot(store: store, report: report)
    }

    package func rebuild() throws -> RebuildReport {
        try withMaterializeLock {
            try rebuildUnlocked()
        }
    }

    package func rebuildUnlocked() throws -> RebuildReport {
        try bootstrap()
        let snapshot = try replayJournal()
        return try rebuildUnlocked(from: snapshot)
    }

    private func rebuildUnlocked(from snapshot: JournalSnapshot) throws -> RebuildReport {
        let store = snapshot.store
        let report = snapshot.report
        try materializeFromStore(store, report: report)
        let counts = try mirrorCounts(at: mirrorURL())
        return RebuildReport(
            approvedPatchIDs: report.approvedPatchIDs,
            rejectedPatchIDs: report.rejectedPatchIDs,
            pendingPatchIDs: report.pendingPatchIDs,
            mirrorCounts: counts
        )
    }

    private func applyUnlocked(
        _ plan: KnowledgePatchPlan,
        receipt: PatchDecisionReceipt,
        existingSnapshot: JournalSnapshot
    ) throws -> ApplyResult {
        let committed = try commitDecision(plan, receipt: receipt, onto: existingSnapshot)
        do {
            let rebuild = try rebuildUnlocked(from: committed.snapshot)
            return ApplyResult(patchID: plan.patchID, decision: receipt.decision.rawValue, rebuild: rebuild)
        } catch {
            throw ASKPostCommitMaterializationError(
                patchID: plan.patchID,
                decision: receipt.decision,
                cause: String(describing: error)
            )
        }
    }

    /// Validates the complete canonical transition before publishing a decision.
    /// Materialization consumes that exact snapshot; it never performs semantic
    /// validation after the point at which a decision becomes durable.
    private func commitDecision(
        _ plan: KnowledgePatchPlan,
        receipt: PatchDecisionReceipt,
        onto existingSnapshot: JournalSnapshot
    ) throws -> (snapshot: JournalSnapshot, didCommit: Bool) {
        try plan.validate()
        try receipt.validate()
        if plan.patchID != receipt.patchID {
            throw ASKError.validation("patch receipt does not match plan")
        }

        if let existingStatus = existingSnapshot.store.patchStatus(plan.patchID), existingStatus != .pending {
            guard try loadPatchPlan(patchID: plan.patchID) == plan,
                  try loadPatchReceipt(patchID: plan.patchID) == receipt
            else {
                throw ASKError.journalConflict(
                    "patch `\(plan.patchID)` is already decided with different contents"
                )
            }
            // The journal already contains this decision. Replaying repairs any
            // stale report without folding the same decision twice.
            return (try replayJournal(), false)
        }
        try ensureRawInputsForPlan(plan, receipt: receipt)

        // Receipt timestamps and patch IDs determine replay order, not arrival
        // order. Even an append can overlap standalone journal events, so use
        // the canonical fold rather than maintaining a second append authority.
        let validated = try replayJournal(candidate: (plan, receipt))
        try publishPatchEntry(plan: plan, receipt: receipt)
        return (validated, true)
    }

    /// Commits several decisions and derives the outputs once.
    ///
    /// Applying one at a time re-derives everything per decision, so ingesting
    /// `n` patches costs `n` materializations: the canonical write is small but
    /// the derived work is proportional to the whole vault. A batch pays that
    /// once. Decisions are committed in order and a failure stops the batch —
    /// whatever was already written to the journal stays committed and is
    /// materialized, because a canonical commit is never reported as rolled back.
    package func applyBatch(
        _ decisions: [(plan: KnowledgePatchPlan, receipt: PatchDecisionReceipt)]
    ) throws -> BatchApplyResult {
        try withMaterializeLock {
            try bootstrap()
            var snapshot = try loadJournalSnapshot()
            var applied: [ApplyDecisionSummary] = []
            var failure: BatchApplyFailure?

            for decision in decisions {
                do {
                    let committed = try commitDecision(decision.plan, receipt: decision.receipt, onto: snapshot)
                    snapshot = committed.snapshot
                    if committed.didCommit {
                        applied.append(
                            ApplyDecisionSummary(
                                patchID: decision.plan.patchID,
                                decision: decision.receipt.decision.rawValue
                            )
                        )
                    }
                } catch {
                    failure = BatchApplyFailure(patchID: decision.plan.patchID, message: "\(error)")
                    break
                }
            }

            do {
                let rebuild = try rebuildUnlocked(from: snapshot)
                return BatchApplyResult(applied: applied, rebuild: rebuild, failure: failure)
            } catch {
                throw ASKBatchPostCommitMaterializationError(
                    applied: applied,
                    failure: failure,
                    cause: String(describing: error)
                )
            }
        }
    }
}
