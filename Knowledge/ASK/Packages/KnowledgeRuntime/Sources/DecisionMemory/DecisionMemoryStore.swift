import Foundation
import KnowledgeCore
import KnowledgeRuntime

public struct DecisionMemoryReplay: Sendable, Equatable {
    public let snapshot: MemoryLifecycleSnapshot
    public let generation: String
    public let recordCount: Int
    public let transitionCount: Int

    public init(
        snapshot: MemoryLifecycleSnapshot,
        generation: String,
        recordCount: Int,
        transitionCount: Int
    ) {
        self.snapshot = snapshot
        self.generation = generation
        self.recordCount = recordCount
        self.transitionCount = transitionCount
    }
}

public struct DecisionMemoryMaterialization: Sendable, Equatable {
    public let replay: DecisionMemoryReplay
    public let files: [String]

    public init(replay: DecisionMemoryReplay, files: [String]) {
        self.replay = replay
        self.files = files
    }
}

public struct DecisionMemoryProjectionDrift: Sendable, Equatable {
    public let missingOrDifferentFiles: [String]

    public init(missingOrDifferentFiles: [String]) {
        self.missingOrDifferentFiles = missingOrDifferentFiles
    }

    public var isClean: Bool { missingOrDifferentFiles.isEmpty }
}

/// Canonical decision-memory journal and derived Markdown projection adapter.
///
/// The type owns no action capability: it appends/replays lifecycle facts and
/// renders views. Calling workflows must interpret an intervention separately.
public actor DecisionMemoryStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    @discardableResult
    public func append(_ record: MemoryRecord) throws -> DecisionMemoryReplay {
        try append([record])
    }

    /// Appends many records under one lock and one journal load. Duplicate IDs
    /// with identical content are skipped; conflicting content fails the whole
    /// batch before anything is written.
    public func append(_ records: [MemoryRecord]) throws -> DecisionMemoryReplay {
        guard !records.isEmpty else {
            throw ASKError.validation("decision-memory record batch must not be empty")
        }
        let vault = Vault(root: root)
        return try vault.withMaterializeLock {
            var journal = try loadJournal(vault: vault)
            var pendingFiles: [(url: URL, record: MemoryRecord, wasPreexisting: Bool)] = []
            pendingFiles.reserveCapacity(records.count)

            do {
                for record in records {
                    if let existing = journal.records.first(where: { $0.recordID == record.recordID }) {
                        guard existing == record else {
                            throw ASKError.journalConflict("decision-memory record conflict: \(record.recordID)")
                        }
                        continue
                    }
                    journal.records.append(record)
                    let url = recordURL(vault: vault, recordID: record.recordID)
                    pendingFiles.append((url, record, FileManager.default.fileExists(atPath: url.path)))
                }
                guard !pendingFiles.isEmpty else {
                    let last = records[records.count - 1]
                    return try makeReplay(journal: journal, asOf: last.createdAt)
                }
                let finalAsOf = pendingFiles.last!.record.createdAt
                let replay = try makeReplay(journal: journal, asOf: finalAsOf)
                for (url, record, _) in pendingFiles {
                    try persistEntry(vault: vault, url: url, payload: record)
                }
                return replay
            } catch {
                var cleanupFailures: [String] = []
                for (url, _, wasPreexisting) in pendingFiles.reversed() where !wasPreexisting {
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        cleanupFailures.append("\(url.path): \(error)")
                    }
                }
                if cleanupFailures.isEmpty {
                    throw error
                }
                throw ASKError.apply(
                    "decision-memory batch append failed: \(error); rollback failures: \(cleanupFailures.joined(separator: "; "))"
                )
            }
        }
    }

    @discardableResult
    public func append(_ transition: MemoryTransition) throws -> DecisionMemoryReplay {
        let vault = Vault(root: root)
        return try vault.withMaterializeLock {
            let journal = try loadJournal(vault: vault)
            if let existing = journal.transitions.first(where: { $0.transitionID == transition.transitionID }) {
                guard existing == transition else {
                    throw ASKError.journalConflict("decision-memory transition conflict: \(transition.transitionID)")
                }
                return try makeReplay(journal: journal, asOf: transition.occurredAt)
            }
            var prospective = journal
            prospective.transitions.append(transition)
            let replay = try makeReplay(journal: prospective, asOf: transition.occurredAt)
            try persistEntry(
                vault: vault,
                url: transitionURL(vault: vault, transitionID: transition.transitionID),
                payload: transition
            )
            return replay
        }
    }

    /// Replays canonical state without creating a missing vault or projection.
    /// Allows an adapter to preserve successful replay before a new external
    /// admission check. append still performs the authoritative conflict check.
    public func containsIdenticalTransition(_ transition: MemoryTransition) throws -> Bool {
        let journal = try loadJournal(vault: Vault(root: root))
        guard let existing = journal.transitions.first(where: { $0.transitionID == transition.transitionID }) else { return false }
        guard existing == transition else {
            throw ASKError.journalConflict("decision-memory transition conflict: \(transition.transitionID)")
        }
        return true
    }

    /// Replays canonical state without creating a missing vault or projection.
    public func replay(asOf: String) throws -> DecisionMemoryReplay {
        let vault = Vault(root: root)
        return try makeReplay(journal: loadJournal(vault: vault), asOf: asOf)
    }

    /// Produces task-specific memory context with no model or embedding call.
    public func context(
        for frame: TaskFrame,
        budget: ContextBudget = ContextBudget()
    ) throws -> ContextBundle {
        let replay = try self.replay(asOf: frame.requestedAt)
        return try DeterministicContextCompiler().compile(
            snapshot: replay.snapshot,
            frame: frame,
            generation: replay.generation,
            budget: budget
        )
    }

    /// Rebuilds all generated Markdown views from the canonical journal while
    /// sharing the knowledge-vault materialization lock.
    @discardableResult
    public func materialize(asOf: String) throws -> DecisionMemoryMaterialization {
        let vault = Vault(root: root)
        return try vault.withMaterializeLock {
            let replay = try makeReplay(journal: loadJournal(vault: vault), asOf: asOf)
            let outputs = projectionOutputs(replay: replay)
            let obsolete = projectionPaths(replay: replay).subtracting(outputs.map(\.relativePath))
            for path in obsolete.union(outputs.map(\.relativePath)) {
                _ = try vault.validatedVaultURL(vault.root.appendingPathComponent(path))
            }
            for path in obsolete.sorted() {
                try vault.removeGeneratedFile(path)
            }
            for output in outputs {
                try vault.writeTextFile(vault.root.appendingPathComponent(output.relativePath), content: output.content)
            }
            return DecisionMemoryMaterialization(replay: replay, files: outputs.map(\.relativePath))
        }
    }

    /// Checks generated Markdown against the canonical replay without writing.
    public func projectionDrift(asOf: String) throws -> DecisionMemoryProjectionDrift {
        let replay = try self.replay(asOf: asOf)
        let outputs = projectionOutputs(replay: replay)
        var drift = outputs.compactMap { output -> String? in
            let url = root.appendingPathComponent(output.relativePath)
            guard let existing = try? String(contentsOf: url, encoding: .utf8), existing == normalized(output.content) else {
                return output.relativePath
            }
            return nil
        }
        for path in projectionPaths(replay: replay).subtracting(outputs.map(\.relativePath)) {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                drift.append(path)
            }
        }
        return DecisionMemoryProjectionDrift(missingOrDifferentFiles: drift.sorted())
    }
}

private struct DecisionMemoryJournal {
    var records: [MemoryRecord]
    var transitions: [MemoryTransition]
}

private struct DecisionMemoryProjectionOutput {
    let relativePath: String
    let content: String
}

private extension DecisionMemoryStore {
    func projectionPaths(replay: DecisionMemoryReplay) -> Set<String> {
        let workspaces = Set(replay.snapshot.states.map { $0.record.scope.workspaceID })
        return Set(workspaces.flatMap { workspaceID in
            MemoryTier.allCases.map { "memory/\($0.rawValue)/\(workspaceID).md" }
        })
    }

    func loadJournal(vault: Vault) throws -> DecisionMemoryJournal {
        let storage = vault.root.appendingPathComponent(".ask/decision-memory", isDirectory: true)
        if FileManager.default.fileExists(atPath: storage.path) {
            let namespaces = try FileManager.default.contentsOfDirectory(at: storage,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            guard namespaces.allSatisfy({ $0.lastPathComponent == "v2" }) else {
                throw ASKError.validation("unsupported decision-memory storage; expected v2")
            }
        }
        let records = try loadEntries(
            type: MemoryRecord.self,
            directory: vault.root.appendingPathComponent(".ask/decision-memory/v2/records", isDirectory: true),
            expectedID: { $0.recordID }
        )
        let transitions = try loadEntries(
            type: MemoryTransition.self,
            directory: vault.root.appendingPathComponent(".ask/decision-memory/v2/transitions", isDirectory: true),
            expectedID: { $0.transitionID }
        )
        return DecisionMemoryJournal(records: records, transitions: transitions)
    }

    func loadEntries<Entry: Decodable & ASKValidatable>(
        type: Entry.Type,
        directory: URL,
        expectedID: (Entry) -> String
    ) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw ASKError.validation("decision-memory journal entry is not a regular file: \(url.path)")
                }
                let entry = try CanonicalJSON.decode(Entry.self, from: Data(contentsOf: url))
                try entry.validate()
                let expectedFileName = "\(expectedID(entry)).json"
                guard url.lastPathComponent == expectedFileName else {
                    throw ASKError.validation("decision-memory journal entry has non-canonical name: \(url.lastPathComponent)")
                }
                return entry
            }
    }

    func makeReplay(journal: DecisionMemoryJournal, asOf: String) throws -> DecisionMemoryReplay {
        let snapshot = try DecisionMemoryReducer.replay(
            records: journal.records,
            transitions: journal.transitions,
            asOf: asOf
        )
        let generation = try generation(for: journal)
        return DecisionMemoryReplay(
            snapshot: snapshot,
            generation: generation,
            recordCount: journal.records.count,
            transitionCount: journal.transitions.count
        )
    }

    func generation(for journal: DecisionMemoryJournal) throws -> String {
        let recordBytes = try journal.records
            .sorted { $0.recordID < $1.recordID }
            .map(CanonicalJSON.string)
        let transitionBytes = try journal.transitions
            .sorted { $0.transitionID < $1.transitionID }
            .map(CanonicalJSON.string)
        return stableHash([decisionMemoryRecordVersion] + recordBytes + [decisionMemoryTransitionVersion] + transitionBytes)
    }

    func recordURL(vault: Vault, recordID: String) -> URL {
        vault.root.appendingPathComponent(".ask/decision-memory/v2/records/\(recordID).json")
    }

    func transitionURL(vault: Vault, transitionID: String) -> URL {
        vault.root.appendingPathComponent(".ask/decision-memory/v2/transitions/\(transitionID).json")
    }

    func projectionOutputs(replay: DecisionMemoryReplay) -> [DecisionMemoryProjectionOutput] {
        let activeStates = replay.snapshot.states.filter(\.isActive)
        let readme = """
        # Decision Memory

        Generated from the canonical decision-memory journal. Do not edit this file as a source of truth.

        - generation: \(replay.generation)
        - records: \(replay.recordCount)
        - transitions: \(replay.transitionCount)
        """
        var outputs = [DecisionMemoryProjectionOutput(relativePath: "memory/README.md", content: readme)]
        for tier in MemoryTier.allCases {
            let states = activeStates.filter { $0.tier == tier }
            let workspaces = Set(states.map { $0.record.scope.workspaceID })
            for workspaceID in workspaces.sorted() {
                let scopedStates = states
                    .filter { $0.record.scope.workspaceID == workspaceID }
                    .sorted(by: projectionOrder)
                outputs.append(
                    DecisionMemoryProjectionOutput(
                        relativePath: "memory/\(tier.rawValue)/\(workspaceID).md",
                        content: renderTier(
                            tier: tier,
                            workspaceID: workspaceID,
                            states: scopedStates,
                            generation: replay.generation
                        )
                    )
                )
            }
        }
        return outputs.sorted { $0.relativePath < $1.relativePath }
    }

    func renderTier(
        tier: MemoryTier,
        workspaceID: String,
        states: [MemoryRecordState],
        generation: String
    ) -> String {
        var lines = [
            "# \(tier.rawValue.uppercased()) decision memory",
            "",
            "- workspace: \(workspaceID)",
            "- generation: \(generation)",
        ]
        for state in states {
            let record = state.record
            let evidence = state.evidenceRefs.map(\.evidenceID).sorted().joined(separator: ", ")
            lines += [
                "",
                "## \(record.recordID)",
                "",
                "- kind: \(record.kind.rawValue)",
                "- subject: \(record.subject.kind)/\(record.subject.subjectID)",
                "- priority: \(record.priority)",
                "- blocking: \(record.blocking ? "true" : "false")",
                "- verified_at: \(state.verifiedAt ?? "none")",
                "- evidence: \(evidence.isEmpty ? "none" : evidence)",
                "",
                record.statement,
            ]
        }
        return lines.joined(separator: "\n")
    }

    func projectionOrder(_ lhs: MemoryRecordState, _ rhs: MemoryRecordState) -> Bool {
        if lhs.record.blocking != rhs.record.blocking { return lhs.record.blocking }
        if lhs.record.priority != rhs.record.priority { return lhs.record.priority > rhs.record.priority }
        let left = ASKTimestamp.OrderKey(lhs.effectiveFrom)
        let right = ASKTimestamp.OrderKey(rhs.effectiveFrom)
        if left != right { return left < right }
        return lhs.record.recordID < rhs.record.recordID
    }

    func normalized(_ content: String) -> String {
        content.hasSuffix("\n") ? content : content + "\n"
    }

    func persistEntry<Entry: Encodable>(vault: Vault, url: URL, payload: Entry) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            try vault.persistJournalFile(url, payload: payload)
        } catch {
            let writeError = error
            guard !existed, FileManager.default.fileExists(atPath: url.path) else {
                throw writeError
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ASKError.apply(
                    "decision-memory journal write failed: \(writeError); rollback failure: \(error)"
                )
            }
            throw writeError
        }
    }
}
