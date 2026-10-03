import Testing
@testable import KnowledgeCore

struct DecisionMemoryContractsTests {
    private let scope = MemoryScope(
        workspaceID: "ask",
        projectIDs: ["pageindex"],
        pathPrefixes: ["packages/pageindex"],
        capabilityTags: ["index"],
        riskTags: ["correctness"]
    )

    private func record(
        recordID: String = "mem_001",
        kind: MemoryRecordKind = .constraint,
        authorityID: String? = "auth_pageindex",
        expiresAt: String? = nil
    ) -> MemoryRecord {
        MemoryRecord(
            recordID: recordID,
            kind: kind,
            subject: MemorySubject(kind: "package", subjectID: "pageindex"),
            scope: scope,
            taskID: "task_001",
            statement: "Use source-backed anchors for factual answers.",
            priority: 90,
            blocking: kind == .constraint,
            createdAt: "2026-08-01T00:00:00Z",
            expiresAt: expiresAt,
            authorityID: authorityID
        )
    }

    private func freshEvidence() -> MemoryEvidenceRef {
        MemoryEvidenceRef(
            evidenceID: "evidence_001",
            kind: .pageIndexAnchor,
            freshness: .fresh,
            sourceID: "src_pageindex",
            nodeID: "node_001",
                    exactAnchor: MemoryExactSourceAnchor(sourceVersionChecksum: "source-revision",
                        coordinateSpace: "line", rangeStart: 1, rangeEnd: 1,
                        contentSHA256: String(repeating: "a", count: 64))
        )
    }

    @Test
    func verifiedRecordPromotesFromStimToMtemThenLtsm() throws {
        let memory = record()
        let snapshot = try DecisionMemoryReducer.replay(
            records: [memory],
            transitions: [
                MemoryTransition(
                    transitionID: "transition_001",
                    recordID: memory.recordID,
                    kind: .verify,
                    occurredAt: "2026-08-01T00:01:00Z",
                    actorID: "reviewer",
                    reason: "anchor checked",
                    evidenceRefs: [freshEvidence()]
                ),
                MemoryTransition(
                    transitionID: "transition_002",
                    recordID: memory.recordID,
                    kind: .promote,
                    occurredAt: "2026-08-01T00:02:00Z",
                    actorID: "reviewer",
                    reason: "reused by project",
                    targetTier: .mtem
                ),
                MemoryTransition(
                    transitionID: "transition_003",
                    recordID: memory.recordID,
                    kind: .promote,
                    occurredAt: "2026-08-01T00:03:00Z",
                    actorID: "owner",
                    reason: "approved invariant",
                    targetTier: .ltsm
                ),
            ],
            asOf: "2026-08-01T00:04:00Z"
        )

        let state = try #require(snapshot.state(recordID: memory.recordID))
        #expect(state.tier == .ltsm)
        #expect(state.verification == .verified)
        #expect(state.disposition == .active)
        #expect(state.evidenceRefs == [freshEvidence()])
    }

    @Test
    func reducerRejectsPromotionWithoutVerificationAndDirectLtsmPromotion() throws {
        let memory = record()
        let promote = MemoryTransition(
            transitionID: "transition_001",
            recordID: memory.recordID,
            kind: .promote,
            occurredAt: "2026-08-01T00:01:00Z",
            actorID: "reviewer",
            reason: "skip verification",
            targetTier: .ltsm
        )

        #expect(throws: ASKError.self) {
            _ = try DecisionMemoryReducer.replay(
                records: [memory],
                transitions: [promote],
                asOf: "2026-08-01T00:02:00Z"
            )
        }
    }

    @Test
    func verificationRejectsStaleEvidenceAndExpiredRecordsLeaveActiveState() throws {
        let stale = MemoryEvidenceRef(
            evidenceID: "evidence_001",
            kind: .pageIndexAnchor,
            freshness: .stale,
            sourceID: "src_pageindex",
            nodeID: "node_001",
                    exactAnchor: MemoryExactSourceAnchor(sourceVersionChecksum: "source-revision",
                        coordinateSpace: "line", rangeStart: 1, rangeEnd: 1,
                        contentSHA256: String(repeating: "a", count: 64))
        )
        let memory = record(expiresAt: "2026-08-01T00:02:00Z")
        let staleVerification = MemoryTransition(
            transitionID: "transition_001",
            recordID: memory.recordID,
            kind: .verify,
            occurredAt: "2026-08-01T00:01:00Z",
            actorID: "reviewer",
            reason: "stale anchor",
            evidenceRefs: [stale]
        )
        #expect(throws: ASKError.self) { try staleVerification.validate() }

        let snapshot = try DecisionMemoryReducer.replay(
            records: [memory],
            transitions: [],
            asOf: "2026-08-01T00:03:00Z"
        )
        #expect(snapshot.state(recordID: memory.recordID)?.disposition == .expired)
    }

    @Test
    func supersessionIsAuditableAndExcludesThePriorRecord() throws {
        let first = record(recordID: "mem_001")
        let replacement = record(recordID: "mem_002")
        let snapshot = try DecisionMemoryReducer.replay(
            records: [first, replacement],
            transitions: [
                MemoryTransition(
                    transitionID: "transition_001",
                    recordID: first.recordID,
                    kind: .supersede,
                    occurredAt: "2026-08-01T00:01:00Z",
                    actorID: "owner",
                    reason: "newer verified policy",
                    replacementRecordID: replacement.recordID
                ),
            ],
            asOf: "2026-08-01T00:02:00Z"
        )

        #expect(snapshot.state(recordID: first.recordID)?.disposition == .superseded)
        #expect(snapshot.state(recordID: replacement.recordID)?.disposition == .active)
    }
}
