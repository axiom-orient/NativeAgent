import Foundation
import KnowledgePresentation
import KnowledgeRuntime
import XCTest
@testable import ASKTutor

private enum TutorPostCommitFilesystemFault {
    case appliedRecordIsDirectory
    case presentationBundleIsFile
    case candidateDirectoryIsReadOnly

    var effect: TutorInsightPostCommitEffect {
        switch self {
        case .appliedRecordIsDirectory: return .persistAppliedRecord
        case .presentationBundleIsFile: return .materializePresentation
        case .candidateDirectoryIsReadOnly: return .removeCandidate
        }
    }
}

private enum TutorPostCommitTestError: Error {
    case expectedFailureMissing
}

extension ASKProductIntegrationTests {
    func testKnowledgePipelineAppliedRecordWriteFailureKeepsCommitAndCanResume() async throws {
        try await verifyTutorPostCommitFilesystemFault(.appliedRecordIsDirectory)
    }

    func testKnowledgePipelinePresentationWriteFailureKeepsCommitAndCanResume() async throws {
        try await verifyTutorPostCommitFilesystemFault(.presentationBundleIsFile)
    }

    func testKnowledgePipelineCandidateDeleteFailureKeepsCommitAndCanResume() async throws {
        try await verifyTutorPostCommitFilesystemFault(.candidateDirectoryIsReadOnly)
    }

    private func verifyTutorPostCommitFilesystemFault(
        _ fault: TutorPostCommitFilesystemFault
    ) async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let workspace = ASKProductWorkspacePaths(rootURL: rootURL)
        // Always undo the permission fault before cleaning the isolated test tree.
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: workspace.pendingTutorInsightsRoot.path
            )
            try? fileManager.removeItem(at: rootURL)
        }
        let maintainer = ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot)
        try maintainer.ensureKnowledgeBase()
        let pipeline = try ASKKnowledgePipeline(workspace: workspace, maintainer: maintainer)
        let candidate = try pipeline.captureStudyPlan(
            learnerID: "learner-post-commit-filesystem",
            plan: TutorStudyPlan(
                learnerID: "learner-post-commit-filesystem",
                generatedAt: "2026-04-13T11:00:00Z",
                headline: "Recover derived tutor outputs",
                focusTopics: ["Recovery"],
                actions: ["Retry the retained candidate with the same decision context"],
                rationale: ["Canonical knowledge and derived outputs have different commit boundaries."],
                dueConceptIDs: [],
                knowledgeMaintenance: []
            ),
            candidateID: "candidate-post-commit-filesystem"
        )
        let proposal = try pipeline.buildProposal(candidateID: candidate.candidateID)
        let appliedRecordURL = workspace.appliedTutorInsightsRoot
            .appendingPathComponent(candidate.candidateID + ".json")
        let presentationBundleURL = try workspace.presentationBundleRoot(
            named: proposal.targetProjectionSlug
        )
        let decidedBy = "filesystem-reviewer"
        let decidedAt = "2026-04-13T11:01:00Z"
        let reason = "Verified explicit filesystem recovery"
        let before = try maintainer.snapshot()

        switch fault {
        case .appliedRecordIsDirectory:
            // The atomic JSON write cannot replace a directory.
            try fileManager.createDirectory(at: appliedRecordURL, withIntermediateDirectories: true)
        case .presentationBundleIsFile:
            // Keep the top-level presentation root intact: PageIndex's
            // ensureDirectories() must succeed before the intended failure.
            try fileManager.createDirectory(
                at: presentationBundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("blocked presentation directory".utf8).write(to: presentationBundleURL)
        case .candidateDirectoryIsReadOnly:
            // Candidate reads still work; the final unlink must fail while
            // canonical/applied/PageIndex/presentation directories remain writable.
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o500)],
                ofItemAtPath: workspace.pendingTutorInsightsRoot.path
            )
            // Skip only if this host bypasses filesystem permission checks.
            // A privileged process cannot qualify this real EACCES failure.
            let permissionProbe = workspace.pendingTutorInsightsRoot
                .appendingPathComponent("permission-probe")
            var hostEnforcesPermissions = false
            do {
                try Data("probe".utf8).write(to: permissionProbe)
            } catch {
                hostEnforcesPermissions = true
            }
            if !hostEnforcesPermissions {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: workspace.pendingTutorInsightsRoot.path
                )
                try fileManager.removeItem(at: permissionProbe)
                throw XCTSkip("This host bypasses POSIX write permissions; candidate unlink fault is NOT_RUN")
            }
        }

        let observedError: TutorInsightPostCommitError
        do {
            _ = try await pipeline.applyCandidate(
                candidateID: candidate.candidateID,
                decidedBy: decidedBy,
                decidedAt: decidedAt,
                reason: reason
            )
            XCTFail("Expected post-commit failure at \(fault.effect.rawValue)")
            throw TutorPostCommitTestError.expectedFailureMissing
        } catch let error as TutorInsightPostCommitError {
            observedError = error
        }
        XCTAssertEqual(observedError.failedEffect, fault.effect)
        XCTAssertEqual(observedError.committedRecord.patchID, proposal.patch.patchID)
        XCTAssertEqual(observedError.committedRecord.decidedBy, decidedBy)
        XCTAssertEqual(observedError.committedRecord.decidedAt, decidedAt)
        XCTAssertEqual(observedError.committedRecord.reason, reason)
        XCTAssertFalse(observedError.cause.isEmpty)

        let committed = try maintainer.snapshot()
        XCTAssertEqual(committed.approvedPatchIDs.count, before.approvedPatchIDs.count + 1)
        XCTAssertTrue(committed.approvedPatchIDs.contains(proposal.patch.patchID))
        XCTAssertNotNil(try pipeline.candidateStore.load(candidateID: candidate.candidateID))
        if fault.effect != .persistAppliedRecord {
            let applied = try XCTUnwrap(pipeline.appliedStore.load(candidateID: candidate.candidateID))
            XCTAssertEqual(applied.patchID, proposal.patch.patchID)
            XCTAssertEqual(applied.decidedAt, decidedAt)
        }

        switch fault {
        case .appliedRecordIsDirectory:
            try fileManager.removeItem(at: appliedRecordURL)
            XCTAssertNil(try pipeline.appliedStore.load(candidateID: candidate.candidateID))
        case .presentationBundleIsFile:
            try fileManager.removeItem(at: presentationBundleURL)
        case .candidateDirectoryIsReadOnly:
            // Earlier derived effects must already have completed.
            XCTAssertTrue(fileManager.fileExists(
                atPath: presentationBundleURL
                    .appendingPathComponent("askpage.runtime.json").path
            ))
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: workspace.pendingTutorInsightsRoot.path
            )
        }

        let repaired = try await pipeline.applyCandidate(
            candidateID: candidate.candidateID,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            reason: reason
        )
        XCTAssertEqual(repaired.record.patchID, proposal.patch.patchID)
        XCTAssertEqual(repaired.record.decidedBy, decidedBy)
        XCTAssertEqual(repaired.record.decidedAt, decidedAt)
        XCTAssertEqual(repaired.record.reason, reason)
        XCTAssertNil(try pipeline.candidateStore.load(candidateID: candidate.candidateID))
        let persisted = try XCTUnwrap(pipeline.appliedStore.load(candidateID: candidate.candidateID))
        XCTAssertEqual(persisted.patchID, proposal.patch.patchID)
        let afterRetry = try maintainer.snapshot()
        XCTAssertEqual(afterRetry.approvedPatchIDs, committed.approvedPatchIDs)
        XCTAssertTrue(fileManager.fileExists(
            atPath: presentationBundleURL.appendingPathComponent("askpage.runtime.json").path
        ))
    }
}
