import DecisionMemory
import Foundation
import KnowledgeCore
import PageIndex

private struct ScenarioFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private final class ScenarioRunner {
    private(set) var total = 0
    private(set) var passed = 0
    private var failures: [(String, String)] = []

    func check(_ name: String, _ body: @Sendable () async throws -> Void) async {
        total += 1
        do {
            try await body()
            passed += 1
            print("SCENARIO PASS \(name)")
        } catch {
            failures.append((name, String(describing: error)))
            print("SCENARIO FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("SCENARIO SUMMARY total=\(total) passed=\(passed) failed=\(failures.count)")
        if !failures.isEmpty {
            for (name, reason) in failures {
                print("SCENARIO FAILURE name=\(name) reason=\(reason)")
            }
            Foundation.exit(1)
        }
        Foundation.exit(0)
    }
}

private struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func shuffled<T>(_ values: [T]) -> [T] {
        var result = values
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let other = Int(next() % UInt64(index + 1))
            result.swapAt(index, other)
        }
        return result
    }
}

private struct CountingTokenCounter: TokenCounting {
    func countTokens(in text: String, model: String?) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct StaticNavigator: VectorlessTreeNavigating {
    let modelCallCost: Int
    let response: @Sendable (VectorlessNavigationPrompt) -> String

    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        response(prompt)
    }
}

private struct ThrowingNavigator: VectorlessTreeNavigating {
    let modelCallCost: Int

    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        throw ScenarioFailure(message: "synthetic navigator transport failure")
    }
}

private enum ScenarioSupport {
    static let scope = MemoryScope(
        workspaceID: "ask",
        projectIDs: ["pageindex"],
        pathPrefixes: ["packages/pageindex"],
        capabilityTags: ["index"],
        riskTags: ["correctness"],
        consequenceTags: ["external"]
    )

    static let frame = TaskFrame(
        taskID: "task_scenario",
        workspaceID: "ask",
        projectIDs: ["pageindex"],
        paths: ["packages/pageindex/sources/pageindex"],
        capabilityTags: ["index"],
        riskTags: ["correctness"],
        consequenceTags: ["external"],
        requestedAt: "2026-08-02T00:30:00Z"
    )

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ScenarioFailure(message: message) }
    }

    static func requireThrows(_ body: () throws -> Void, _ message: String) throws {
        do {
            try body()
            throw ScenarioFailure(message: message)
        } catch is ScenarioFailure {
            throw ScenarioFailure(message: message)
        } catch {
            return
        }
    }

    static func requireAsyncThrows(_ body: () async throws -> Void, _ message: String) async throws {
        do {
            try await body()
            throw ScenarioFailure(message: message)
        } catch is ScenarioFailure {
            throw ScenarioFailure(message: message)
        } catch {
            return
        }
    }

    static func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func memoryRecord(
        id: String,
        statement: String,
        kind: MemoryRecordKind = .constraint,
        blocking: Bool = false,
        priority: Int = 50,
        taskID: String? = "task_scenario",
        createdAt: String = "2026-08-02T00:00:00Z"
    ) -> MemoryRecord {
        MemoryRecord(
            recordID: id,
            kind: kind,
            subject: MemorySubject(kind: "package", subjectID: "pageindex"),
            scope: scope,
            taskID: taskID,
            statement: statement,
            priority: priority,
            blocking: blocking,
            createdAt: createdAt,
            authorityID: blocking ? "authority_pageindex" : nil
        )
    }

    // Exact identity of artifact()'s node_root and its six frozen UTF-8 excerpts.
    // These scenarios exercise the memory domain; source I/O is tested separately.
    static let memoryEvidenceAnchor = MemoryExactSourceAnchor(
        sourceVersionChecksum: "checksum_scenario_001",
        coordinateSpace: "line",
        rangeStart: 1,
        rangeEnd: 6,
        contentSHA256: "28377d5e6b1fae1b301ecb2da692aa9af59f32996387ad07d1e50c6a6558d2d0"
    )

    static func verifyTransition(recordID: String, id: String, at: String, evidenceID: String = "evidence_scenario") -> MemoryTransition {
        MemoryTransition(
            transitionID: id,
            recordID: recordID,
            kind: .verify,
            occurredAt: at,
            actorID: "scenario_reviewer",
            reason: "deterministic scenario evidence",
            evidenceRefs: [
                MemoryEvidenceRef(
                    evidenceID: evidenceID,
                    kind: .pageIndexAnchor,
                    freshness: .fresh,
                    sourceID: "src_scenario",
                    nodeID: "node_root",
                    exactAnchor: memoryEvidenceAnchor
                )
            ]
        )
    }

    static func validOptions() -> ASKPageIndexOptions {
        ASKPageIndexOptions(
            model: nil,
            retrieveModel: nil,
            tocCheckPageNum: 20,
            maxPageNumEachNode: 10,
            maxTokenNumEachNode: 20_000,
            ifAddNodeID: .yes,
            ifAddNodeSummary: .no,
            ifAddDocDescription: .no,
            ifAddNodeText: .yes
        )
    }

    static func artifact(
        sourceID: SourceID = "src_scenario",
        quality: SourceExtractionQuality = .digitalText,
        sourcePath: String? = "/tmp/irregular/문서 [v1].md"
    ) throws -> SourceIndexArtifact {
        let childRange = try SourceRange(space: .line, start: 4, end: 6)
        let rootRange = try SourceRange(space: .line, start: 1, end: 6)
        let child = SourceIndexNode(
            nodeID: "node_child",
            title: "결론 🧭 / خاتمة",
            range: childRange,
            summary: "Unicode and irregular source",
            snippet: "evidence ✅",
            children: []
        )
        let root = SourceIndexNode(
            nodeID: "node_root",
            title: "Root",
            range: rootRange,
            summary: "Scenario source",
            snippet: "root",
            children: [child]
        )
        let document = SourceIndexDocument(
            sourceID: sourceID,
            type: .md,
            title: "문서 / document",
            description: "CJK العربية é 👩‍💻",
            coordinateSpace: .line,
            extentCount: 6,
            rootNodes: [root]
        )
        return SourceIndexArtifact(
            document: document,
            excerpts: [
                SourceExcerpt(index: 1, content: "# Root\r"),
                SourceExcerpt(index: 2, content: "intro\u{200B} \u{1F4A1}"),
                SourceExcerpt(index: 3, content: "```md"),
                SourceExcerpt(index: 4, content: "## 결론 🧭 / خاتمة"),
                SourceExcerpt(index: 5, content: "line with e\u{301} and \u{1F469}\u{200D}\u{1F4BB}"),
                SourceExcerpt(index: 6, content: "```"),
            ],
            version: SourceVersion(checksum: "checksum_scenario_001", contentLength: 128, modifiedAt: nil),
            sourcePath: sourcePath,
            extractionQuality: quality
        )
    }

    static func staticNodeNavigator(
        nodeIDs: [String],
        sufficient: Bool = true,
        modelCallCost: Int = 1
    ) -> StaticNavigator {
        StaticNavigator(modelCallCost: modelCallCost) { prompt in
            let sourceIDs = prompt.stage == .corpus ? prompt.candidates.map(\.sourceID.rawValue) : []
            let selectedNodes = prompt.stage == .document ? nodeIDs : []
            return "{\"source_ids\":\(jsonArray(sourceIDs)),\"node_ids\":\(jsonArray(selectedNodes)),\"sufficient\":\(sufficient ? "true" : "false")}" 
        }
    }

    static func staticPathNavigator(
        nodeIDs: [String],
        sufficient: Bool = true,
        modelCallCost: Int = 1
    ) -> StaticNavigator {
        StaticNavigator(modelCallCost: modelCallCost) { prompt in
            let sourceIDs = prompt.stage == .corpus ? prompt.candidates.map(\.sourceID.rawValue) : []
            let candidateIDs = prompt.candidates.map(\.id)
            let selectedNodes = prompt.stage == .document
                ? nodeIDs.filter { candidateIDs.contains($0) }
                : []
            return "{\"source_ids\":\(jsonArray(sourceIDs)),\"node_ids\":\(jsonArray(selectedNodes)),\"sufficient\":\(sufficient ? "true" : "false")}" 
        }
    }

    private static func jsonArray(_ values: [String]) -> String {
        let data = try! JSONEncoder().encode(values)
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonArrayForScenario(_ values: [String]) -> String {
        jsonArray(values)
    }
}

@main
struct ScenarioConsumer {
    static func main() async {
        if let markerIndex = CommandLine.arguments.firstIndex(of: "--markdown-case"),
           CommandLine.arguments.indices.contains(markerIndex + 1),
           let caseIndex = Int(CommandLine.arguments[markerIndex + 1]) {
            do {
                try await markdownAdversarialCase(caseIndex)
                print("SCENARIO PASS markdown.case-\(caseIndex)")
                Foundation.exit(0)
            } catch {
                print("SCENARIO FAIL markdown.case-\(caseIndex): \(error)")
                Foundation.exit(1)
            }
        }
        if CommandLine.arguments.contains("--markdown-generated") {
            do {
                try await generatedMarkdownCorpus()
                print("SCENARIO PASS markdown.generated-corpus")
                Foundation.exit(0)
            } catch {
                print("SCENARIO FAIL markdown.generated-corpus: \(error)")
                Foundation.exit(1)
            }
        }
        if let markerIndex = CommandLine.arguments.firstIndex(of: "--markdown-generated-case"),
           CommandLine.arguments.indices.contains(markerIndex + 1),
           let caseIndex = Int(CommandLine.arguments[markerIndex + 1]) {
            do {
                try await generatedMarkdownCase(caseIndex)
                print("SCENARIO PASS markdown.generated-case-\(caseIndex)")
                Foundation.exit(0)
            } catch {
                print("SCENARIO FAIL markdown.generated-case-\(caseIndex): \(error)")
                Foundation.exit(1)
            }
        }
        let coreOnly = CommandLine.arguments.contains("--core")
        let runner = ScenarioRunner()
        await runner.check("memory.lifecycle-replay-permutation") {
            try memoryLifecycleReplayPermutation()
        }
        await runner.check("memory.invalid-contract-matrix") {
            try invalidContractMatrix()
        }
        await runner.check("memory.store-restart-projection-drift") {
            try await memoryStoreRestartAndProjectionDrift()
        }
        await runner.check("memory.context-unicode-budget-intervention") {
            try await contextUnicodeBudgetAndIntervention()
        }
        await runner.check("integration.concurrent-memory-and-pageindex-writes") {
            try await concurrentMemoryAndPageIndexWrites()
        }
        if !coreOnly {
            await runner.check("markdown.syntax-adversarial-corpus") {
                try await markdownAdversarialCorpus()
            }
            await runner.check("markdown.deterministic-generated-corpus") {
                try await generatedMarkdownCorpus()
            }
        }
        await runner.check("pageindex.source-reingest-restart-and-backlink") {
            try await sourceReingestRestartAndBacklink()
        }
        await runner.check("rag.success-unicode-and-version-anchor") {
            try await ragSuccessUnicodeAndVersionAnchor()
        }
        await runner.check("rag.failure-and-budget-matrix") {
            try await ragFailureAndBudgetMatrix()
        }
        await runner.check("rag.mixed-invalid-id-fails-closed") {
            try await ragMixedInvalidIDFailsClosed()
        }
        await runner.check("rag.scope-and-quality-matrix") {
            try await ragScopeAndQualityMatrix()
        }
        runner.finish()
    }

    private static func memoryLifecycleReplayPermutation() throws {
        var rng = DeterministicRNG(seed: 0xA5A5_2026)
        var records: [MemoryRecord] = []
        var transitions: [MemoryTransition] = []
        for index in 0..<48 {
            let second = String(format: "%02d", index % 60)
            let statement = "규칙 \(index) — e\u{301} 👩‍💻\nline \(index) \u{200B} العربية"
            let recordID = String(format: "mem_%03d", index)
            records.append(
                ScenarioSupport.memoryRecord(
                    id: recordID,
                    statement: statement,
                    kind: index.isMultiple(of: 3) ? .constraint : .observation,
                    blocking: index.isMultiple(of: 9),
                    priority: index % 101,
                    createdAt: "2026-08-02T00:\(second):00Z"
                )
            )
            transitions.append(
                ScenarioSupport.verifyTransition(
                    recordID: recordID,
                    id: String(format: "transition_%03d", index),
                    at: "2026-08-02T01:\(second):00Z",
                    evidenceID: String(format: "evidence_%03d", index)
                )
            )
        }
        let canonical = try DecisionMemoryReducer.replay(
            records: records,
            transitions: transitions,
            asOf: "2026-08-02T02:00:00Z"
        )
        for _ in 0..<40 {
            let replayed = try DecisionMemoryReducer.replay(
                records: rng.shuffled(records),
                transitions: rng.shuffled(transitions),
                asOf: "2026-08-02T02:00:00Z"
            )
            try ScenarioSupport.require(replayed == canonical, "replay changed under input permutation")
        }
        try ScenarioSupport.require(canonical.states.count == records.count, "not every generated record survived replay")
        try ScenarioSupport.require(canonical.states.allSatisfy { $0.verification == .verified }, "verified transitions were not applied")
    }

    private static func invalidContractMatrix() throws {
        let base = ScenarioSupport.memoryRecord(id: "mem_valid", statement: "valid", kind: .constraint)
        var invalidRecord = base
        invalidRecord.recordID = "../escape"
        try ScenarioSupport.requireThrows({ try invalidRecord.validate() }, "path traversal record ID was accepted")
        invalidRecord = base
        invalidRecord.statement = ""
        try ScenarioSupport.requireThrows({ try invalidRecord.validate() }, "empty statement was accepted")
        invalidRecord = base
        invalidRecord.priority = 101
        try ScenarioSupport.requireThrows({ try invalidRecord.validate() }, "out-of-range priority was accepted")
        invalidRecord = base
        invalidRecord.initialTier = .mtem
        try ScenarioSupport.requireThrows({ try invalidRecord.validate() }, "non-STIM initial tier was accepted")
        invalidRecord = ScenarioSupport.memoryRecord(id: "mem_invalid", statement: "invalid", kind: .procedure, blocking: true)
        try ScenarioSupport.requireThrows({ try invalidRecord.validate() }, "blocking non-constraint record was accepted")

        let directLTSM = MemoryTransition(
            transitionID: "transition_direct",
            recordID: base.recordID,
            kind: .promote,
            occurredAt: "2026-08-02T00:01:00Z",
            actorID: "reviewer",
            reason: "skip",
            targetTier: .ltsm
        )
        try ScenarioSupport.requireThrows({
            _ = try DecisionMemoryReducer.replay(records: [base], transitions: [directLTSM], asOf: "2026-08-02T00:02:00Z")
        }, "direct LTSM promotion was accepted")

        let stale = MemoryTransition(
            transitionID: "transition_stale",
            recordID: base.recordID,
            kind: .verify,
            occurredAt: "2026-08-02T00:01:00Z",
            actorID: "reviewer",
            reason: "stale",
            evidenceRefs: [MemoryEvidenceRef(evidenceID: "old", kind: .pageIndexAnchor, freshness: .stale, sourceID: "src_scenario", nodeID: "node_root", exactAnchor: ScenarioSupport.memoryEvidenceAnchor)]
        )
        try ScenarioSupport.requireThrows({ try stale.validate() }, "stale evidence verified a record")

        let malformedPageIndexEvidence = MemoryEvidenceRef(evidenceID: "bad", kind: .pageIndexAnchor, freshness: .fresh, sourceID: "src_scenario", nodeID: nil, exactAnchor: ScenarioSupport.memoryEvidenceAnchor)
        try ScenarioSupport.requireThrows({ try malformedPageIndexEvidence.validate() }, "page-index evidence without node was accepted")

        let malformedScope = MemoryScope(workspaceID: "ask", projectIDs: ["z", "a"])
        try ScenarioSupport.requireThrows({ try malformedScope.validate() }, "unordered scope IDs were accepted")
    }

    private static func memoryStoreRestartAndProjectionDrift() async throws {
        let root = try ScenarioSupport.temporaryDirectory("memory-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ScenarioSupport.memoryRecord(
            id: "mem_restart",
            statement: "Restart must preserve canonical journal bytes.",
            kind: .constraint,
            blocking: true,
            priority: 99
        )
        let verification = ScenarioSupport.verifyTransition(
            recordID: record.recordID,
            id: "transition_restart",
            at: "2026-08-02T00:01:00Z"
        )
        let store = DecisionMemoryStore(root: root)
        _ = try await store.append(record)
        _ = try await store.append(verification)
        _ = try await store.append(MemoryTransition(transitionID: "transition_restart_mtem", recordID: record.recordID, kind: .promote, occurredAt: "2026-08-02T00:02:00Z", actorID: "reviewer", reason: "reuse", targetTier: .mtem))
        _ = try await store.append(MemoryTransition(transitionID: "transition_restart_ltsm", recordID: record.recordID, kind: .promote, occurredAt: "2026-08-02T00:03:00Z", actorID: "owner", reason: "authority", targetTier: .ltsm))
        let before = try await store.replay(asOf: "2026-08-02T00:04:00Z")
        let materialized = try await store.materialize(asOf: "2026-08-02T00:04:00Z")
        try ScenarioSupport.require(materialized.files.contains("memory/README.md"), "materialization omitted README")
        let restarted = DecisionMemoryStore(root: root)
        let after = try await restarted.replay(asOf: "2026-08-02T00:04:00Z")
        try ScenarioSupport.require(before == after, "restart changed replay")
        let freshDrift = try await restarted.projectionDrift(asOf: "2026-08-02T00:04:00Z")
        try ScenarioSupport.require(freshDrift.isClean, "fresh projection was reported as drifted")

        let projection = root.appendingPathComponent("memory/ltsm/ask.md")
        try "tampered".write(to: projection, atomically: true, encoding: .utf8)
        let tamperedDrift = try await restarted.projectionDrift(asOf: "2026-08-02T00:04:00Z")
        try ScenarioSupport.require(!tamperedDrift.isClean, "tampered projection was not detected")
        _ = try await restarted.materialize(asOf: "2026-08-02T00:04:00Z")
        let rebuiltDrift = try await restarted.projectionDrift(asOf: "2026-08-02T00:04:00Z")
        try ScenarioSupport.require(rebuiltDrift.isClean, "projection rebuild did not clear drift")

        let recordURL = root.appendingPathComponent(".ask/decision-memory/v2/records/mem_restart.json")
        try Data("{not-json".utf8).write(to: recordURL, options: .atomic)
        try await ScenarioSupport.requireAsyncThrows({ _ = try await restarted.replay(asOf: "2026-08-02T00:04:00Z") }, "corrupt canonical journal was treated as empty")
    }

    private static func contextUnicodeBudgetAndIntervention() async throws {
        let root = try ScenarioSupport.temporaryDirectory("memory-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DecisionMemoryStore(root: root)
        let proposed = ScenarioSupport.memoryRecord(id: "mem_proposed", statement: "검증 전 제약 🚧\nsecond line", kind: .constraint, blocking: true, priority: 100)
        let verified = ScenarioSupport.memoryRecord(id: "mem_verified", statement: "verified long-term rule — العربية", kind: .constraint, blocking: true, priority: 99)
        _ = try await store.append(proposed)
        _ = try await store.append(verified)
        _ = try await store.append(ScenarioSupport.verifyTransition(recordID: verified.recordID, id: "transition_verified", at: "2026-08-02T00:01:00Z"))
        _ = try await store.append(MemoryTransition(transitionID: "transition_mtem", recordID: verified.recordID, kind: .promote, occurredAt: "2026-08-02T00:02:00Z", actorID: "reviewer", reason: "reuse", targetTier: .mtem))
        _ = try await store.append(MemoryTransition(transitionID: "transition_ltsm", recordID: verified.recordID, kind: .promote, occurredAt: "2026-08-02T00:03:00Z", actorID: "owner", reason: "authority", targetTier: .ltsm))

        let frame = ScenarioSupport.frame
        let bundle = try await store.context(for: frame)
        let repeated = try await store.context(for: frame)
        try ScenarioSupport.require(bundle == repeated, "context changed across identical calls")
        try ScenarioSupport.require(bundle.records.map(\.recordID) == ["mem_proposed", "mem_verified"], "context priority/order was unstable")
        try ScenarioSupport.require(bundle.markdown.contains("검증 전 제약"), "Unicode proposed statement was lost")
        let intervention = DecisionMemoryIntervention.decide(bundle: bundle, frame: TaskFrame(taskID: frame.taskID, workspaceID: frame.workspaceID, projectIDs: frame.projectIDs, paths: frame.paths, capabilityTags: frame.capabilityTags, riskTags: ["correctness", "irreversible"], consequenceTags: frame.consequenceTags, requestedAt: frame.requestedAt))
        try ScenarioSupport.require(intervention.kind == .requireVerification, "proposed constraint did not require verification")

        try ScenarioSupport.requireThrows({
            _ = try DeterministicContextCompiler().compile(snapshot: bundle.records.isEmpty ? MemoryLifecycleSnapshot(states: []) : try DecisionMemoryReducer.replay(records: [verified], transitions: [ScenarioSupport.verifyTransition(recordID: verified.recordID, id: "transition_x", at: "2026-08-02T00:01:00Z")], asOf: frame.requestedAt), frame: frame, generation: "tiny", budget: ContextBudget(blockingLTSMTokens: 1, ltsmTokens: 1, mtemTokens: 0, stimTokens: 0, uncertaintyTokens: 0, totalTokens: 2))
        }, "blocking LTSM record exceeded budget without failure")
    }

    private static func concurrentMemoryAndPageIndexWrites() async throws {
        let root = try ScenarioSupport.temporaryDirectory("concurrent-writes")
        defer { try? FileManager.default.removeItem(at: root) }

        let memoryStore = DecisionMemoryStore(root: root)
        let records = (0..<24).map { index in
            ScenarioSupport.memoryRecord(
                id: String(format: "mem_concurrent_%02d", index),
                statement: "concurrent record \(index) 🧪"
            )
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask {
                    _ = try await memoryStore.append(record)
                }
            }
            try await group.waitForAll()
        }
        let replayed = try await memoryStore.replay(asOf: "2026-08-02T00:30:00Z")
        try ScenarioSupport.require(replayed.recordCount == records.count && replayed.snapshot.states.count == records.count, "concurrent memory appends lost records")

        let sourceURL = root.appendingPathComponent("동시성 문서.md")
        try "# Root\nbody\n\n## Child\nchild\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let services = try [
            ASKPageIndexExtension(workspaceURL: root),
            ASKPageIndexExtension(workspaceURL: root),
        ]
        var manifests: [SourceIndexManifestEntry] = []
        try await withThrowingTaskGroup(of: SourceIndexManifestEntry.self) { group in
            for service in services {
                group.addTask {
                    try await service.ingest(sourceAt: sourceURL)
                }
            }
            for try await manifest in group {
                manifests.append(manifest)
            }
        }
        try ScenarioSupport.require(Set(manifests.map(\.sourceID)).count == 1, "concurrent source ingest forked logical source identity")
        let restarted = try ASKPageIndexExtension(workspaceURL: root)
        let entries = try await restarted.listSources()
        try ScenarioSupport.require(entries.count == 1, "concurrent source ingest duplicated manifest entries")
        guard let sourceID = entries.first?.sourceID else {
            throw ScenarioFailure(message: "concurrent source ingest produced no manifest")
        }
        try "# Root\nchanged\n\n## Child\nchanged child\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        _ = try await withThrowingTaskGroup(of: SourceIndexManifestEntry.self, returning: [SourceIndexManifestEntry].self) { group in
            for service in services {
                group.addTask {
                    try await service.update(sourceAt: sourceURL)
                }
            }
            var updates: [SourceIndexManifestEntry] = []
            for try await update in group {
                updates.append(update)
            }
            return updates
        }
        let afterUpdate = try await restarted.listSources()
        try ScenarioSupport.require(afterUpdate.count == 1 && afterUpdate[0].sourceID == sourceID, "concurrent update changed manifest cardinality or source identity")
        try ScenarioSupport.require((try await restarted.artifact(sourceID: sourceID))?.version.checksum != nil, "concurrent update left no readable artifact")
    }

    private static func markdownAdversarialCorpus() async throws {
        for index in markdownCases().indices {
            try await markdownAdversarialCase(index)
        }
    }

    private static func markdownAdversarialCase(_ index: Int) async throws {
        let cases = markdownCases()
        guard cases.indices.contains(index) else {
            throw ScenarioFailure(message: "unknown Markdown case index \(index)")
        }
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        let markdown = cases[index]
        let first = try await indexer.index(markdownContent: markdown, sourceName: "case-\(index)", sourcePath: "/tmp/case-\(index).md", options: ScenarioSupport.validOptions())
        let second = try await indexer.index(markdownContent: markdown, sourceName: "case-\(index)", sourcePath: "/tmp/case-\(index).md", options: ScenarioSupport.validOptions())
        try ScenarioSupport.require(first == second, "Markdown result changed for irregular case \(index)")
        try ScenarioSupport.require((first.lineCount ?? 0) >= 1, "Markdown line count was invalid for case \(index)")
        let nodes = DocumentTreeUtilities.flatten(first.structure ?? [])
        var prior = 0
        for node in nodes {
            let lineNumber = node.lineNumber ?? 0
            try ScenarioSupport.require(lineNumber >= prior, "node ranges moved backward in case \(index)")
            prior = lineNumber
        }
        try ScenarioSupport.require(!nodes.contains { $0.title.contains("Not a heading") }, "fenced heading became an index node")
    }

    private static func markdownCases() -> [String] {
        [
            "",
            "\n\n",
            "# 한글 제목\r\n본문 👩‍💻\r\n\r\n## العربية\r\nنص",
            "intro\n\nSetext\n======\nbody\n",
            "# Real\n```md\n# Not a heading\n## Also code\n```\n## Real child\n",
            "  # Two-space heading\n   # Three-space heading\n    # Four-space code?\n",
            "### jump\ntext\n# reset\n## child\n",
            "# [link](https://example.com) `code` *emphasis* # trailing close #\ntext",
            "# e\u{301} / e\u{301}\n\n## zero\u{200B}width\n\n## 👩‍💻",
            "> # quoted heading\n\n- # list content\n\n# actual",
        ]
    }

    private static func generatedMarkdownCorpus() async throws {
        for documentIndex in 0..<120 {
            try await generatedMarkdownCase(documentIndex)
        }
    }

    private static func generatedMarkdownCase(_ documentIndex: Int) async throws {
        guard (0..<120).contains(documentIndex) else {
            throw ScenarioFailure(message: "unknown generated Markdown case index \(documentIndex)")
        }
        let indexer = MarkdownIndexer(tokenCounter: CountingTokenCounter())
        var rng = DeterministicRNG(seed: 0x2026_0802)
        var markdown = ""
        for currentIndex in 0...documentIndex {
            var lines: [String] = []
            if currentIndex.isMultiple(of: 4) { lines += ["preamble 🧪", ""] }
            for sectionIndex in 0..<Int(rng.next() % 9) {
                let level = Int(rng.next() % 6) + 1
                let title = ["CJK 문서", "العربية", "e\u{301}", "emoji 👩‍💻", "quote #", "plain"][Int(rng.next() % 6)]
                lines.append(String(repeating: "#", count: level) + " " + title + " \(sectionIndex)")
                if rng.next().isMultiple(of: 3) {
                    lines += ["```text", "# inside fence", "```"]
                }
                lines += ["body \(rng.next()) \u{200B}", ""]
            }
            if currentIndex == documentIndex {
                markdown = lines.joined(separator: currentIndex.isMultiple(of: 5) ? "\r\n" : "\n")
            }
        }
        let first = try await indexer.index(markdownContent: markdown, sourceName: "generated-\(documentIndex)", options: ScenarioSupport.validOptions())
        let second = try await indexer.index(markdownContent: markdown, sourceName: "generated-\(documentIndex)", options: ScenarioSupport.validOptions())
        try ScenarioSupport.require(first == second, "generated Markdown case \(documentIndex) was nondeterministic")
        for node in DocumentTreeUtilities.flatten(first.structure ?? []) {
            try ScenarioSupport.require((node.lineNumber ?? 0) <= (first.lineCount ?? 0), "generated node escaped document extent")
        }
    }

    private static func sourceReingestRestartAndBacklink() async throws {
        let root = try ScenarioSupport.temporaryDirectory("pageindex-workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("문서 [v1].md")
        try "# Root\nbody\n\n## Child\nchild\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let service = try ASKPageIndexExtension(workspaceURL: root)
        let first = try await service.ingest(sourceAt: sourceURL)
        let firstArtifact = try await service.artifact(sourceID: first.sourceID)
        try ScenarioSupport.require(firstArtifact?.extractionQuality == .digitalText, "Markdown extraction was not digital text")
        guard let firstNodeID = firstArtifact?.document.rootNodes.first?.nodeID,
              let oldAnchor = try await service.makeAnchor(sourceID: first.sourceID, nodeID: firstNodeID)
        else { throw ScenarioFailure(message: "first source anchor could not be created") }
        _ = try await service.attach(knowledgeID: "knowledge/irregular", anchors: [oldAnchor, oldAnchor])
        try "# Root\nchanged\n\n## New child\nnew\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let second = try await service.update(sourceAt: sourceURL)
        try ScenarioSupport.require(first.sourceID == second.sourceID, "logical source ID changed on re-ingest")
        try ScenarioSupport.require(first.version.checksum != second.version.checksum, "source checksum did not change")
        let restarted = try ASKPageIndexExtension(workspaceURL: root)
        let entries = try await restarted.listSources()
        try ScenarioSupport.require(entries.count == 1, "restart duplicated source manifest entry")
        let oldResolution = try await restarted.resolve(anchor: oldAnchor)
        try ScenarioSupport.require(oldResolution?.anchor.sourceVersionChecksum == first.version.checksum, "historical anchor did not resolve to its version")
        let backlink = try await restarted.auditBacklink(knowledgeID: "knowledge/irregular")
        try ScenarioSupport.require(backlink.resolved.map(\.anchor) == [oldAnchor] && backlink.unresolved.isEmpty, "historical backlink did not resolve to its version")
        try await restarted.delete(sourceID: first.sourceID)
        let remainingEntries = try await restarted.listSources()
        try ScenarioSupport.require(remainingEntries.isEmpty, "source delete left manifest entry")
        let deletedBacklink = try await restarted.auditBacklink(knowledgeID: "knowledge/irregular")
        try ScenarioSupport.require(deletedBacklink.resolved.isEmpty, "deleted source remained resolvable")
    }

    private static func ragSuccessUnicodeAndVersionAnchor() async throws {
        let artifact = try ScenarioSupport.artifact()
        let query = SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "결론 خاتمة", maxTreeDepth: 3, maxVisitedNodes: 5, maxRawEvidenceTokens: 100, maxModelCalls: 2)
        let result = try await VectorlessTreeRAG(navigator: ScenarioSupport.staticPathNavigator(nodeIDs: ["node_root", "node_child"])).retrieve(query: query, artifacts: [artifact])
        try ScenarioSupport.require(result.answerability == .sufficient, "Unicode child was not retrievable")
        try ScenarioSupport.require(result.excerpts.count == 3, "child range did not open all excerpts")
        try ScenarioSupport.require(result.anchors.first?.sourceVersionChecksum == artifact.version.checksum, "evidence anchor lost source version")
        try ScenarioSupport.require(result.trace.rawEvidenceTokens > 0, "raw evidence token accounting was empty")
    }

    private static func ragFailureAndBudgetMatrix() async throws {
        let artifact = try ScenarioSupport.artifact()
        let missing = SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID, "src_missing"]), question: "question")
        let missingResult = try await VectorlessTreeRAG().retrieve(query: missing, artifacts: [artifact])
        try ScenarioSupport.require(missingResult.answerability == .insufficient && missingResult.excerpts.isEmpty, "missing exact source was silently narrowed")

        let malformed = StaticNavigator(modelCallCost: 1) { _ in "not-json" }
        let malformedResult = try await VectorlessTreeRAG(navigator: malformed).retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question"), artifacts: [artifact])
        try ScenarioSupport.require(malformedResult.answerability == .insufficient && malformedResult.excerpts.isEmpty, "malformed navigator JSON produced evidence")

        let transport = try await VectorlessTreeRAG(navigator: ThrowingNavigator(modelCallCost: 1)).retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question"), artifacts: [artifact])
        try ScenarioSupport.require(transport.answerability == .insufficient && transport.excerpts.isEmpty, "navigator transport failure produced evidence")

        let zeroBudget = try await VectorlessTreeRAG(navigator: ScenarioSupport.staticNodeNavigator(nodeIDs: ["node_child"], modelCallCost: 1)).retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question", maxModelCalls: 0), artifacts: [artifact])
        try ScenarioSupport.require(zeroBudget.answerability == .insufficient && zeroBudget.trace.modelCalls == 0, "model call cap was not enforced before provider call")

        let rawCap = try await VectorlessTreeRAG(navigator: ScenarioSupport.staticPathNavigator(nodeIDs: ["node_root", "node_child"])).retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question", maxRawEvidenceTokens: 1), artifacts: [artifact])
        try ScenarioSupport.require(rawCap.answerability == .insufficient, "raw evidence cap was ignored")

        let depthCap = try await VectorlessTreeRAG(navigator: ScenarioSupport.staticPathNavigator(nodeIDs: ["node_root", "node_child"])).retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question", maxTreeDepth: 1), artifacts: [artifact])
        try ScenarioSupport.require(depthCap.answerability == .sufficient && depthCap.trace.visitedNodeIDs == ["node_root"], "depth cap exceeded or failed to return bounded node evidence")

        let explicitInsufficient = try await VectorlessTreeRAG(navigator: ScenarioSupport.staticPathNavigator(nodeIDs: ["node_root", "node_child"], sufficient: false)).retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question"), artifacts: [artifact])
        try ScenarioSupport.require(explicitInsufficient.answerability == .insufficient && explicitInsufficient.excerpts.isEmpty, "navigator insufficiency was overridden")
    }

    private static func ragScopeAndQualityMatrix() async throws {
        let blocked = try ScenarioSupport.artifact(sourceID: "src_blocked", quality: .ocrRequired)
        let uncertain = try ScenarioSupport.artifact(sourceID: "src_uncertain", quality: .layoutUncertain, sourcePath: "/safe/docs/uncertain.md")
        let inScope = try ScenarioSupport.artifact(sourceID: "src_in_scope", sourcePath: "/safe/docs/in-scope.md")
        let outScope = try ScenarioSupport.artifact(sourceID: "src_out_scope", sourcePath: "/elsewhere/out.md")
        let blockedResult = try await VectorlessTreeRAG().retrieve(query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [blocked.document.sourceID]), question: "question"), artifacts: [blocked])
        try ScenarioSupport.require(blockedResult.answerability == .extractionBlocked && blockedResult.excerpts.isEmpty, "OCR-required source was opened")

        let scopedQuery = SourceEvidenceQuery(sourceSelection: .scoped(corpusScope: SourceCorpusScope(types: [.md], pathPrefixes: ["/safe/docs/"], maxSources: 4)), question: "결론", maxModelCalls: 0)
        let scopedResult = try await VectorlessTreeRAG().retrieve(query: scopedQuery, artifacts: [uncertain, inScope, outScope])
        try ScenarioSupport.require(scopedResult.trace.selectedSourceIDs.isEmpty || scopedResult.trace.selectedSourceIDs.allSatisfy { $0 == uncertain.document.sourceID || $0 == inScope.document.sourceID }, "path scope selected an out-of-scope source")
        try ScenarioSupport.require(scopedResult.trace.modelCalls == 0, "lexical scope retrieval consumed model budget")

        let invalidQueries: [SourceEvidenceQuery] = [
            SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: []), question: "question"),
            SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: ["src_dup", "src_dup"]), question: "question"),
            SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: ["src_valid"]), question: "   "),
            SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: ["src_valid"]), question: "question", maxTreeDepth: 0),
        ]
        for query in invalidQueries {
            try await ScenarioSupport.requireAsyncThrows({ _ = try await VectorlessTreeRAG().retrieve(query: query, artifacts: [inScope]) }, "invalid RAG query was accepted")
        }
    }

    private static func ragMixedInvalidIDFailsClosed() async throws {
        let artifact = try ScenarioSupport.artifact()
        let navigator = StaticNavigator(modelCallCost: 1) { prompt in
            let sourceIDs = prompt.stage == .corpus ? prompt.candidates.map(\.sourceID.rawValue) : []
            let candidateIDs = prompt.candidates.map(\.id)
            let selectedNodes: [String]
            if prompt.stage == .document, candidateIDs.contains("node_root") {
                selectedNodes = ["node_root"]
            } else if prompt.stage == .document {
                selectedNodes = ["node_child", "invented-node"]
            } else {
                selectedNodes = []
            }
            return "{\"source_ids\":\(ScenarioSupport.jsonArrayForScenario(sourceIDs)),\"node_ids\":\(ScenarioSupport.jsonArrayForScenario(selectedNodes)),\"sufficient\":true}"
        }
        let result = try await VectorlessTreeRAG(navigator: navigator).retrieve(
            query: SourceEvidenceQuery(sourceSelection: .exact(sourceIDs: [artifact.document.sourceID]), question: "question"),
            artifacts: [artifact]
        )
        try ScenarioSupport.require(result.answerability == .insufficient && result.excerpts.isEmpty, "mixed valid/invalid navigator IDs produced evidence")
    }
}
