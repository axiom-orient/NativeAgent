import Testing
@testable import DecisionMemory
@testable import KnowledgeCore

struct DeterministicContextCompilerTests {
    private let scope = MemoryScope(
        workspaceID: "ask",
        projectIDs: ["pageindex"],
        pathPrefixes: ["packages/pageindex"],
        capabilityTags: ["index"],
        riskTags: ["correctness"]
    )

    private func frame(riskTags: [String] = ["correctness"]) -> TaskFrame {
        TaskFrame(
            taskID: "task_001",
            workspaceID: "ask",
            projectIDs: ["pageindex"],
            paths: ["packages/pageindex/sources"],
            capabilityTags: ["index"],
            riskTags: riskTags,
            requestedAt: "2026-08-01T00:10:00Z"
        )
    }

    private func state(
        recordID: String,
        tier: MemoryTier,
        verification: MemoryVerificationState,
        blocking: Bool = false,
        priority: Int = 50,
        taskID: String? = "task_001"
    ) -> MemoryRecordState {
        MemoryRecordState(
            record: MemoryRecord(
                recordID: recordID,
                kind: blocking ? .constraint : .procedure,
                subject: MemorySubject(kind: "package", subjectID: "pageindex"),
                scope: scope,
                taskID: taskID,
                statement: "\(recordID) statement",
                priority: priority,
                blocking: blocking,
                createdAt: "2026-08-01T00:00:00Z",
                authorityID: tier == .ltsm ? "auth_pageindex" : nil
            ),
            tier: tier,
            verification: verification,
            disposition: .active,
            effectiveFrom: "2026-08-01T00:00:00Z",
            effectiveTo: nil,
            verifiedAt: verification == .verified ? "2026-08-01T00:01:00Z" : nil,
            evidenceRefs: verification == .verified ? [
                MemoryEvidenceRef(
                    evidenceID: "evidence_\(recordID)",
                    kind: .pageIndexAnchor,
                    freshness: .fresh,
                    sourceID: "src_pageindex",
                    nodeID: "node_001",
                    exactAnchor: MemoryExactSourceAnchor(sourceVersionChecksum: "source-revision",
                        coordinateSpace: "line", rangeStart: 1, rangeEnd: 1,
                        contentSHA256: String(repeating: "a", count: 64))
                ),
            ] : []
        )
    }

    @Test
    func compilerSelectsScopeMatchedRecordsWithinBudgetAndIsByteDeterministic() throws {
        let snapshot = MemoryLifecycleSnapshot(states: [
            state(recordID: "mem_ltsm", tier: .ltsm, verification: .verified, blocking: true, priority: 90),
            state(recordID: "mem_mtem", tier: .mtem, verification: .verified, priority: 70),
            state(recordID: "mem_stim", tier: .stim, verification: .proposed, priority: 60),
            state(recordID: "mem_other_task", tier: .stim, verification: .verified, taskID: "task_002"),
        ])
        let compiler = DeterministicContextCompiler()
        let first = try compiler.compile(snapshot: snapshot, frame: frame(), generation: "generation_001")
        let second = try compiler.compile(snapshot: snapshot, frame: frame(), generation: "generation_001")

        #expect(first == second)
        #expect(first.records.map(\.recordID) == ["mem_ltsm", "mem_mtem", "mem_stim"])
        #expect(first.tokenCount <= 1_200)
        #expect(first.markdown.contains("mem_ltsm"))
        #expect(!first.markdown.contains("mem_other_task"))
    }

    @Test
    func compilerFailsRatherThanSilentlyDroppingBlockingLtsmConstraint() throws {
        let snapshot = MemoryLifecycleSnapshot(states: [
            state(recordID: "mem_ltsm", tier: .ltsm, verification: .verified, blocking: true),
        ])
        let budget = ContextBudget(
            blockingLTSMTokens: 1,
            ltsmTokens: 1,
            mtemTokens: 0,
            stimTokens: 0,
            uncertaintyTokens: 0,
            totalTokens: 10
        )
        #expect(throws: DecisionMemoryContextError.self) {
            _ = try DeterministicContextCompiler().compile(
                snapshot: snapshot,
                frame: frame(),
                generation: "generation_001",
                budget: budget
            )
        }
    }

    @Test
    func interventionOnlyReturnsAPolicyDecisionAndNeverPerformsAnAct() throws {
        let snapshot = MemoryLifecycleSnapshot(states: [
            state(recordID: "mem_ltsm", tier: .ltsm, verification: .verified, blocking: true),
        ])
        let bundle = try DeterministicContextCompiler().compile(
            snapshot: snapshot,
            frame: frame(riskTags: ["correctness", "irreversible"]),
            generation: "generation_001"
        )

        let decision = DecisionMemoryIntervention.decide(
            bundle: bundle,
            frame: frame(riskTags: ["correctness", "irreversible"])
        )
        #expect(decision.kind == .block)
        #expect(decision.recordIDs == ["mem_ltsm"])
    }
    @Test(arguments: [-1, Int.max])
    func hostileTokenCounterCannotBypassOrOverflowBudget(cost: Int) throws {
        struct Counter: DecisionMemoryTokenCounting {
            let cost: Int
            func countTokens(in text: String) -> Int {
                text.hasPrefix("# Task context") ? 0 : cost
            }
        }
        let snapshot = MemoryLifecycleSnapshot(states: [
            state(recordID: "first", tier: .ltsm, verification: .verified, blocking: true),
            state(recordID: "second", tier: .ltsm, verification: .verified, blocking: true),
        ])
        #expect(throws: DecisionMemoryContextError.self) {
            _ = try DeterministicContextCompiler(tokenCounter: Counter(cost: cost)).compile(
                snapshot: snapshot, frame: frame(), generation: "generation_001")
        }
    }

    @Test
    func negativeHeaderTokenCountIsRejected() throws {
        struct Counter: DecisionMemoryTokenCounting {
            func countTokens(in text: String) -> Int { -1 }
        }
        #expect(throws: DecisionMemoryContextError.self) {
            _ = try DeterministicContextCompiler(tokenCounter: Counter()).compile(
                snapshot: MemoryLifecycleSnapshot(states: []), frame: frame(), generation: "generation_001")
        }
    }

}
