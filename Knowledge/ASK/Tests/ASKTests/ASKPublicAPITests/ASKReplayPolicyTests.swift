import Foundation
import KnowledgeCore
import XCTest
@testable import ASK

final class ASKReplayPolicyTests: XCTestCase {
    func testEveryEffectingCommandHasAnExplicitReplayPolicy() {
        let workspace = ASKWorkspaceSelection()
        let repairToken = ASKPresentationRepairToken(
            id: "repair",
            actionID: "action",
            knowledgeRootURL: URL(fileURLWithPath: "/tmp/ask-vault"),
            productWorkspaceURL: URL(fileURLWithPath: "/tmp/ask-product"),
            projectionSlugs: ["current/example"],
            createdAt: "2026-07-28T00:00:00Z"
        )
        let commands: [(ASKCommand, ASKReplayPolicy)] = [
            (.quickStart(ASKQuickStartCommand(workspace: workspace, requestedAt: "2026-07-28T00:00:00Z")), .requiresResolution),
            (.indexWorkspace(ASKIndexWorkspaceCommand(
                sourceRootURL: URL(fileURLWithPath: "/tmp/source"),
                workspace: workspace
            )), .replaySafe),
            (.importWorkspace(ASKImportWorkspaceCommand(
                sourceRootURL: URL(fileURLWithPath: "/tmp/source"),
                workspace: workspace,
                title: "Import",
                queryText: "evidence",
                requestedAt: "2026-07-28T00:00:00Z"
            )), .requiresResolution),
            (.stageReport(ASKStageReportCommand(
                workspace: workspace,
                title: "Report",
                queryText: "evidence",
                requestedAt: "2026-07-28T00:00:00Z"
            )), .requiresResolution),
            (.closeDay(ASKCloseDayCommand(
                workspace: workspace,
                date: "2026-07-28",
                requestedAt: "2026-07-28T00:00:00Z"
            )), .requiresResolution),
            (.importCapture(ASKImportCaptureCommand(
                workspace: workspace,
                captureManifestURL: URL(fileURLWithPath: "/tmp/capture.json"),
                domain: "notes",
                requestedAt: "2026-07-28T00:00:00Z"
            )), .requiresResolution),
            (.decidePatch(ASKDecidePatchCommand(
                workspace: workspace,
                patchID: "patch",
                decision: .approved,
                decidedAt: "2026-07-28T00:00:00Z",
                reason: "reviewed"
            )), .requiresResolution),
            (.repairPresentation(ASKRepairPresentationCommand(
                token: repairToken,
                requestedAt: "2026-07-28T00:00:00Z"
            )), .replaySafe),
            (.rebuildKnowledge(ASKRebuildKnowledgeCommand(
                workspace: workspace,
                requestedAt: "2026-07-28T00:00:00Z"
            )), .replaySafe),
            (.recordDecisionMemory(ASKRecordDecisionMemoryCommand(record: MemoryRecord(
                recordID: "mem_replay",
                kind: .observation,
                subject: MemorySubject(kind: "project", subjectID: "ask"),
                scope: MemoryScope(workspaceID: "ask"),
                statement: "replay policy fixture",
                createdAt: "2026-07-28T00:00:00Z"
            ))), .requiresResolution),
            (.recordDecisionMemories(ASKRecordDecisionMemoriesCommand(records: [MemoryRecord(
                recordID: "mem_replay_batch",
                kind: .observation,
                subject: MemorySubject(kind: "project", subjectID: "ask"),
                scope: MemoryScope(workspaceID: "ask"),
                statement: "batch replay policy fixture",
                createdAt: "2026-07-28T00:00:00Z"
            )])), .requiresResolution),
            (.transitionDecisionMemory(ASKTransitionDecisionMemoryCommand(transition: MemoryTransition(
                transitionID: "transition_replay",
                recordID: "mem_replay",
                kind: .retract,
                occurredAt: "2026-07-28T00:01:00Z",
                actorID: "reviewer",
                reason: "fixture"
            ))), .requiresResolution),
            (.consolidateDecisionMemory(ASKConsolidateDecisionMemoryCommand(asOf: "2026-07-28T00:00:00Z")), .requiresResolution),
        ]

        XCTAssertEqual(commands.count, 13, "Update this exhaustive policy table when ASKCommand changes")
        for (command, expected) in commands {
            XCTAssertEqual(command.replayPolicy, expected)
        }
    }

    func testEveryReadQueryIsReplaySafe() {
        let queries: [ASKQuery] = [
            .searchEvidence(ASKEvidenceSearchQuery(text: "evidence")),
            .searchKnowledge(ASKKnowledgeSearchQuery(text: "knowledge")),
            .retrieveEvidence(ASKEvidenceRetrieveQuery(question: "evidence")),
            .projection(ASKProjectionQuery(slug: "current/example")),
            .markdownPage(ASKMarkdownPageQuery(markdown: "# Example")),
            .readingContext(ASKReadingContextQuery(projectionSlug: "current/example")),
            .storageHealth(ASKStorageHealthQuery()),
            .pendingWork(ASKPendingWorkQuery()),
            .sourceInspect(ASKSourceInspectQuery(sourceID: "src_fixture")),
            .pendingPatch(ASKPendingPatchQuery(patchID: "patch_fixture")),
            .decisionMemory(ASKDecisionMemoryQuery(frame: TaskFrame(
                taskID: "task_replay_policy",
                workspaceID: "ask",
                requestedAt: "2026-07-28T00:00:00Z"
            ))),
        ]

        XCTAssertEqual(queries.count, 11, "Update this exhaustive policy table when ASKQuery changes")
        XCTAssertTrue(queries.allSatisfy { $0.replayPolicy == .replaySafe })
    }

    func testReplayPolicyWireValuesMatchExecutorContracts() {
        XCTAssertEqual(ASKReplayPolicy.replaySafe.rawValue, "replay_safe")
        XCTAssertEqual(ASKReplayPolicy.requiresResolution.rawValue, "requires_resolution")
    }
}
