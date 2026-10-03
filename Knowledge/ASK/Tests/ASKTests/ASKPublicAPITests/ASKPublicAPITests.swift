import Foundation
import KnowledgeCore
import XCTest
import ASK

final class ASKPublicAPITests: XCTestCase {
    func testEveryQueryRouteUsesTypedResults() async throws {
        let workspace = temporaryDirectory("queries")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let outcome = try await client.apply(try client.plan(.quickStart(ASKQuickStartCommand(
            requestedAt: "2026-07-26T00:00:00Z", resetExistingWorkspace: true
        ))))
        guard case .workspaceApplied(let applied) = outcome else { return XCTFail("Expected workspace result") }

        let queries: [ASKQuery] = [
            .groundedEvidence(ASKGroundedEvidenceQuery(text: "onboarding quick-start")),
            .searchEvidence(ASKEvidenceSearchQuery(text: "onboarding quick-start")),
            .searchKnowledge(ASKKnowledgeSearchQuery(text: "onboarding quick-start")),
            .retrieveEvidence(ASKEvidenceRetrieveQuery(question: "onboarding quick-start")),
            .projection(ASKProjectionQuery(slug: applied.projectionSlug)),
            .markdownPage(ASKMarkdownPageQuery(markdown: "# Facade\n\nTyped query route.")),
            .readingContext(ASKReadingContextQuery(projectionSlug: applied.projectionSlug)),
            .storageHealth(ASKStorageHealthQuery()),
            .pendingWork(ASKPendingWorkQuery()),
            .decisionMemory(ASKDecisionMemoryQuery(frame: TaskFrame(
                taskID: "task_public_query",
                workspaceID: "ask",
                requestedAt: "2026-07-26T00:00:00Z"
            ))),
        ]

        for query in queries {
            let result = try await client.query(query)
            switch result {
            case .evidenceSearch, .knowledgeSearch, .evidenceRetrieved, .projection, .markdownPage, .readingContext,
                 .storageHealth, .pendingWork, .sourceInspect, .pendingPatch, .decisionMemory,
                 .groundedEvidence, .resolvedEvidence:
                break
            }
        }

        let grounded = try await client.query(
            .groundedEvidence(ASKGroundedEvidenceQuery(text: "onboarding quick-start"))
        )
        guard case .groundedEvidence(let pack) = grounded,
              let reference = pack.evidence.first?.reference else {
            return XCTFail("Expected exact grounded evidence from the current workspace")
        }
        let resolved = try await client.query(
            .resolveEvidence(ASKResolveEvidenceQuery(reference: reference))
        )
        guard case .resolvedEvidence(.available(let content)) = resolved else {
            return XCTFail("Expected the same exact evidence reference to resolve")
        }
        XCTAssertEqual(content.reference, reference)
        XCTAssertEqual(content.sourceFreshness, .ok)

        let evidenceResult = try await client.query(.searchEvidence(ASKEvidenceSearchQuery(text: "onboarding quick-start")))
        guard case .evidenceSearch(let evidenceSearch) = evidenceResult,
              let sourceID = evidenceSearch.items.compactMap(\.sourceID).first else {
            return XCTFail("Expected addressable evidence source")
        }
        let source = try await client.query(.sourceInspect(ASKSourceInspectQuery(sourceID: sourceID)))
        guard case .sourceInspect(let inspected) = source else { return XCTFail("Expected source inspection") }
        XCTAssertEqual(inspected.sourceID, sourceID)

        let stagedForInspection = try await client.apply(try client.plan(.stageReport(ASKStageReportCommand(
            title: "Inspectable", queryText: "onboarding quick-start", requestedAt: "2026-07-26T00:00:30Z"
        ))))
        guard case .staged(.report(let stagedReport)) = stagedForInspection else {
            return XCTFail("Expected staged report")
        }
        let patch = try await client.query(.pendingPatch(ASKPendingPatchQuery(patchID: stagedReport.patchID)))
        guard case .pendingPatch(let detail) = patch else { return XCTFail("Expected pending patch detail") }
        XCTAssertTrue(detail.isPending)
        XCTAssertEqual(detail.plan.patchID, stagedReport.patchID)
    }

    func testStageAndApproveReportUseTypedOutcomes() async throws {
        let workspace = temporaryDirectory("approval")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        _ = try await client.apply(try client.plan(.quickStart(ASKQuickStartCommand(
            requestedAt: "2026-07-26T00:00:00Z", resetExistingWorkspace: true
        ))))

        let staged = try await client.apply(try client.plan(.stageReport(ASKStageReportCommand(
            title: "Follow-up Report", queryText: "onboarding quick-start", requestedAt: "2026-07-26T00:01:00Z"
        ))))
        guard case .staged(.report(let report)) = staged else { return XCTFail("Expected staged report") }

        let relaunched = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let pending = try await relaunched.query(.pendingWork(ASKPendingWorkQuery()))
        guard case .pendingWork(let pendingWork) = pending else { return XCTFail("Expected pending work") }
        XCTAssertEqual(pendingWork.patches.map(\.patchID), [report.patchID])

        let decided = try await relaunched.apply(try relaunched.plan(.decidePatch(ASKDecidePatchCommand(
            patchID: report.patchID, decision: .approved, decidedAt: "2026-07-26T00:02:00Z", reason: "test approval"
        ))))
        guard case .decided(let decision) = decided else { return XCTFail("Expected decision result") }
        XCTAssertEqual(decision.patchID, report.patchID)
        XCTAssertEqual(decision.decision, .approved)
        let resolved = try await relaunched.query(.pendingWork(ASKPendingWorkQuery()))
        guard case .pendingWork(let resolvedWork) = resolved else { return XCTFail("Expected pending work") }
        XCTAssertTrue(resolvedWork.patches.isEmpty)
    }

    func testCloseDayRejectionAndRebuildUseTheCanonicalTypedBoundary() async throws {
        let workspace = temporaryDirectory("close-day-rebuild")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let initial = try await client.apply(client.plan(.quickStart(.init(requestedAt: "2026-07-26T00:00:00Z"))))
        guard case .workspaceApplied(let approved) = initial else { return XCTFail("Expected initial approved report") }

        let staged = try await client.apply(client.plan(.closeDay(.init(
            date: "2026-07-26", queryText: "onboarding quick-start", requestedAt: "2026-07-26T18:00:00Z"
        ))))
        guard case .staged(.closeDay(let closeDay)) = staged else { return XCTFail("Expected pending close-day report") }
        XCTAssertGreaterThan(closeDay.evidenceHitCount, 0)
        let inspected = try await client.query(.pendingPatch(.init(patchID: closeDay.patchID)))
        guard case .pendingPatch(let patch) = inspected else { return XCTFail("Expected inspectable pending patch") }
        XCTAssertTrue(patch.isPending)

        let rejected = try await client.apply(client.plan(.decidePatch(.init(
            patchID: closeDay.patchID, decision: .rejected, decidedAt: "2026-07-26T18:01:00Z", reason: "Needs revision"
        ))))
        guard case .decided(let decision) = rejected else { return XCTFail("Expected explicit rejection") }
        XCTAssertEqual(decision.decision, .rejected)
        XCTAssertEqual(decision.remainingPendingPatchCount, 0)

        let reopened = ASKClient(configuration: client.configuration)
        let result = try await reopened.apply(reopened.plan(.rebuildKnowledge(.init(requestedAt: "2026-07-26T18:02:00Z"))))
        guard case .knowledgeRebuilt(let rebuilt) = result else { return XCTFail("Expected journal rebuild") }
        XCTAssertEqual(rebuilt.approvedPatchIDs, [approved.patchID])
        XCTAssertEqual(rebuilt.rejectedPatchIDs, [closeDay.patchID])
        XCTAssertTrue(rebuilt.pendingPatchIDs.isEmpty)
        let projection = try await reopened.query(.projection(.init(slug: approved.projectionSlug)))
        guard case .projection(let visible) = projection else { return XCTFail("Expected preserved approved projection") }
        XCTAssertEqual(visible.slug, approved.projectionSlug)
    }

    func testTypedBoundaryReturnsDiagnosticForInvalidInputBeforeEffects() throws {
        let workspace = temporaryDirectory("validation")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let command = ASKCommand.stageReport(ASKStageReportCommand(
            title: "Missing query", queryText: "", requestedAt: "2026-07-26T00:00:00Z"
        ))

        XCTAssertThrowsError(try client.plan(command)) { error in
            let diagnostic = error as? ASKDiagnostic
            XCTAssertEqual(diagnostic?.code, .missingField)
            XCTAssertEqual(diagnostic?.context["field"], "queryText")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testQuickStartRequiresReadableCanonicalSnapshotBeforeStartingMutation() async throws {
        let root = temporaryDirectory("snapshot-preflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let blockedVault = workspace.appendingPathComponent("vault-is-a-file")
        let originalVaultBytes = Data("not a vault directory".utf8)
        try originalVaultBytes.write(to: blockedVault)
        let index = workspace.appendingPathComponent("index", isDirectory: true)
        let product = workspace.appendingPathComponent("product", isDirectory: true)
        let client = ASKClient(configuration: ASKConfiguration(
            workspaceURL: workspace,
            vaultURL: blockedVault,
            indexURL: index,
            productWorkspaceURL: product
        ))
        let plan = try client.plan(.quickStart(ASKQuickStartCommand(
            requestedAt: "2026-10-03T00:00:00Z",
            resetExistingWorkspace: true
        )))

        do {
            _ = try await client.apply(plan)
            XCTFail("A mutation must not start without a readable before-state snapshot")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: blockedVault), originalVaultBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: product.path))
    }

    func testMissingWorkspaceQueriesRemainEffectFree() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-public-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let selection = ASKWorkspaceSelection(workspaceURL: workspace)
        let queries: [ASKQuery] = [
            .searchEvidence(ASKEvidenceSearchQuery(workspace: selection, text: "missing")),
            .searchKnowledge(ASKKnowledgeSearchQuery(workspace: selection, text: "missing")),
            .retrieveEvidence(ASKEvidenceRetrieveQuery(workspace: selection, question: "missing")),
            .projection(ASKProjectionQuery(workspace: selection, slug: "missing/projection")),
            .markdownPage(ASKMarkdownPageQuery(markdown: "# Read only")),
            .readingContext(ASKReadingContextQuery(workspace: selection, projectionSlug: "missing/projection")),
            .storageHealth(ASKStorageHealthQuery(workspace: selection)),
            .pendingWork(ASKPendingWorkQuery(workspace: selection)),
            .sourceInspect(ASKSourceInspectQuery(workspace: selection, sourceID: "src_missing")),
            .pendingPatch(ASKPendingPatchQuery(workspace: selection, patchID: "patch_missing")),
            .decisionMemory(ASKDecisionMemoryQuery(
                workspace: selection,
                frame: TaskFrame(
                    taskID: "task_missing_workspace",
                    workspaceID: "ask",
                    requestedAt: "2026-07-26T00:00:00Z"
                )
            )),
        ]

        for query in queries {
            _ = try? await client.query(query)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "Query wrote workspace: \(query)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testDecisionMemoryCommandsRequireExplicitLifecycleFactsAndReturnNonActingAdvice() async throws {
        let workspace = temporaryDirectory("decision-memory")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let selection = ASKWorkspaceSelection(workspaceURL: workspace)
        let record = MemoryRecord(
            recordID: "mem_root_constraint",
            kind: .constraint,
            subject: MemorySubject(kind: "project", subjectID: "pageindex"),
            scope: MemoryScope(workspaceID: "ask", riskTags: ["irreversible"]),
            statement: "Require verified source evidence before irreversible change.",
            priority: 100,
            blocking: true,
            createdAt: "2026-08-01T00:00:00Z",
            authorityID: "authority_pageindex"
        )
        let evidence = MemoryEvidenceRef(
            evidenceID: "receipt_root",
            kind: .humanApproval,
            freshness: .fresh,
            captureReceiptID: "receipt_root"
        )

        let commands: [ASKCommand] = [
            .recordDecisionMemory(ASKRecordDecisionMemoryCommand(workspace: selection, record: record)),
            .transitionDecisionMemory(ASKTransitionDecisionMemoryCommand(workspace: selection, transition: MemoryTransition(
                transitionID: "transition_root_verify",
                recordID: record.recordID,
                kind: .verify,
                occurredAt: "2026-08-01T00:01:00Z",
                actorID: "reviewer",
                reason: "approved evidence",
                evidenceRefs: [evidence]
            ))),
            .transitionDecisionMemory(ASKTransitionDecisionMemoryCommand(workspace: selection, transition: MemoryTransition(
                transitionID: "transition_root_mtem",
                recordID: record.recordID,
                kind: .promote,
                occurredAt: "2026-08-01T00:02:00Z",
                actorID: "reviewer",
                reason: "active constraint",
                targetTier: .mtem
            ))),
            .transitionDecisionMemory(ASKTransitionDecisionMemoryCommand(workspace: selection, transition: MemoryTransition(
                transitionID: "transition_root_ltsm",
                recordID: record.recordID,
                kind: .promote,
                occurredAt: "2026-08-01T00:03:00Z",
                actorID: "reviewer",
                reason: "durable constraint",
                targetTier: .ltsm
            ))),
        ]

        for command in commands {
            let outcome = try await client.apply(try client.plan(command))
            guard case .decisionMemory = outcome else {
                return XCTFail("Expected decision-memory mutation result")
            }
        }

        let advice = try await client.query(.decisionMemory(ASKDecisionMemoryQuery(
            workspace: selection,
            frame: TaskFrame(
                taskID: "task_root_deploy",
                workspaceID: "ask",
                riskTags: ["irreversible"],
                requestedAt: "2026-08-01T00:10:00Z"
            )
        )))
        guard case .decisionMemory(let result) = advice else {
            return XCTFail("Expected decision-memory advice")
        }
        XCTAssertEqual(result.intervention.kind, .block)
        XCTAssertEqual(result.intervention.recordIDs, [record.recordID])

        let consolidated = try await client.apply(try client.plan(.consolidateDecisionMemory(
            ASKConsolidateDecisionMemoryCommand(workspace: selection, asOf: "2026-08-01T00:10:00Z")
        )))
        guard case .decisionMemory(let result) = consolidated else {
            return XCTFail("Expected decision-memory consolidation")
        }
        XCTAssertEqual(result.kind, .consolidate)
        XCTAssertTrue(result.materializedFiles.contains("memory/README.md"))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-public-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}
