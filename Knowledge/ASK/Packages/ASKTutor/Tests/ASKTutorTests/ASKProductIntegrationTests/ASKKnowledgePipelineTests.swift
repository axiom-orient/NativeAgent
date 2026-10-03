import Foundation
import XCTest
@testable import ASKTutor
import KnowledgeCore
import KnowledgeRuntime
import EvidenceIndex
import PageIndex
import DocumentCore
import DocumentRuntime

extension ASKProductIntegrationTests {
    func testKnowledgePipelineApplyBuildsPageIndexArtifactsWhenBindingsAreMissing() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in
                    TutorNarrativeDraft(
                        title: "ASK and Tutor",
                        summary: "Apply should rebuild page index artifacts before rematerializing the presentation.",
                        sections: [
                            TutorNarrativeSection(
                                heading: "Rebuild",
                                body: "Apply the tutor insight, rebuild PageIndex artifacts, then rematerialize the page bundle."
                            )
                        ],
                        comprehensionChecks: ["What gets rebuilt after apply?"],
                        followUpPrompts: ["Inspect the rebuilt page."]
                    )
                }
            )
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try seedASKSourceEvidence(
            rootURL: runtime.workspace.askRoot,
            sourceID: "ask-src-1",
            title: "ASK source",
            body: """
# ASK source

ASK remains the truth owner.

## Tutoring

Tutor teaches from grounded ASK projections.
"""
        )

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T09:30:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK apply rebuild",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T09:31:00Z"
            )
        )
        let reply = try await runtime.tutor.explain(
            TutorExplainRequest(
                sessionID: session.sessionID,
                prompt: "How should apply rebuild the product artifacts?",
                requestedAt: "2026-04-13T09:32:00Z"
            )
        )

        let pipeline = try ASKKnowledgePipeline(
            workspace: runtime.workspace,
            maintainer: ASKRuntimeKnowledgeMaintainer(root: runtime.workspace.askRoot)
        )
        let candidate = try pipeline.captureNarrative(
            learnerID: learner.learnerID,
            session: session,
            prompt: "How should apply rebuild the product artifacts?",
            reply: reply,
            candidateID: "candidate-apply-build"
        )

        let applyResult = try await pipeline.applyCandidate(
            candidateID: candidate.candidateID,
            decidedBy: "reviewer",
            decidedAt: "2026-04-13T09:33:00Z"
        )

        XCTAssertEqual(applyResult.pageIndexBuild.projectionSlug, "wiki/asktutor")
        XCTAssertEqual(applyResult.pageIndexBuild.bindings.map(\.askSourceID), ["ask-src-1"])
        XCTAssertEqual(applyResult.pageIndexBuild.unboundASKSourceIDs, [])
        XCTAssertFalse(applyResult.pageIndexBuild.backlinkAudit.resolved.isEmpty)
        XCTAssertEqual(applyResult.presentation.manifest.pageIndexBindings.map(\.askSourceID), ["ask-src-1"])
        XCTAssertEqual(applyResult.presentation.manifest.unboundSourceIDs, [])

        let readingContext = try await runtime.loadProjectionReadingContext(slug: "wiki/asktutor")
        XCTAssertEqual(readingContext.sourceCatalogs.count, 1)
        XCTAssertEqual(readingContext.sourceCatalogs.first?.askSourceID, "ask-src-1")
        XCTAssertFalse(readingContext.catalogEntries.isEmpty)
        XCTAssertFalse(readingContext.backlinkAudit.resolved.isEmpty)
    }

    func testKnowledgePipelineStagesAppliesAndRegeneratesReadingContext() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try ASKProductReadRuntime(
            workspace: ASKProductWorkspacePaths(rootURL: rootURL),
            model: ProductScriptedModelClient(
                explainHandler: { _ in
                    TutorNarrativeDraft(
                        title: "ASK and Tutor",
                        summary: "Tutor should read from ASK and send verified updates through the pipeline.",
                        sections: [
                            TutorNarrativeSection(
                                heading: "Write-back",
                                body: "Keep ASK as the truth owner. New tutor insights should be reviewed, applied, rebuilt, and then re-presented as pages."
                            )
                        ],
                        comprehensionChecks: ["What stays inside ASK?"],
                        followUpPrompts: ["Review the regenerated page."]
                    )
                }
            )
        )
        try runtime.ensureKnowledgeBase()
        try seedProjectionKnowledge(
            rootURL: runtime.workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: "ASK remains the truth owner. Tutor teaches from grounded projections.",
            sourceIDs: ["ask-src-1"]
        )
        try await seedPageIndex(
            workspace: runtime.workspace,
            askSourceID: "ask-src-1",
            projectionSlug: "wiki/asktutor"
        )

        let learner = try await runtime.tutor.bootstrap(
            TutorBootstrapRequest(
                learnerID: "learner-1",
                displayName: "Ax",
                requestedAt: "2026-04-13T10:00:00Z"
            )
        )
        let session = try await runtime.tutor.startSession(
            TutorStartSessionRequest(
                learnerID: learner.learnerID,
                title: "ASK write-back",
                scope: .projection(slug: "wiki/asktutor"),
                requestedAt: "2026-04-13T10:01:00Z"
            )
        )
        let prompt = "How should the tutoring loop update knowledge and pages?"
        let reply = try await runtime.tutor.explain(
            TutorExplainRequest(
                sessionID: session.sessionID,
                prompt: prompt,
                requestedAt: "2026-04-13T10:02:00Z"
            )
        )

        let maintainer = ASKRuntimeKnowledgeMaintainer(root: runtime.workspace.askRoot)
        let pipeline = try ASKKnowledgePipeline(
            workspace: runtime.workspace,
            maintainer: maintainer
        )
        let candidate = try pipeline.captureNarrative(
            learnerID: learner.learnerID,
            session: session,
            prompt: prompt,
            reply: reply,
            candidateID: "candidate-apply"
        )

        let proposal = try pipeline.stageProposal(candidateID: candidate.candidateID)
        let snapshotAfterStage = try maintainer.snapshot()
        XCTAssertTrue(snapshotAfterStage.pendingPatchIDs.contains(proposal.patch.patchID))

        let applyResult = try await pipeline.applyCandidate(
            candidateID: candidate.candidateID,
            decidedBy: "reviewer",
            decidedAt: "2026-04-13T10:03:00Z"
        )

        let snapshotAfterApply = try maintainer.snapshot()
        XCTAssertTrue(snapshotAfterApply.approvedPatchIDs.contains(proposal.patch.patchID))
        XCTAssertFalse(snapshotAfterApply.pendingPatchIDs.contains(proposal.patch.patchID))
        XCTAssertNil(try pipeline.candidateStore.load(candidateID: candidate.candidateID))

        let appliedRecord = try XCTUnwrap(pipeline.appliedStore.load(candidateID: candidate.candidateID))
        XCTAssertEqual(appliedRecord.patchID, proposal.patch.patchID)
        XCTAssertEqual(applyResult.record, appliedRecord)
        XCTAssertEqual(applyResult.pageIndexBuild.bindings.map(\.askSourceID), ["ask-src-1"])
        XCTAssertEqual(applyResult.pageIndexBuild.unboundASKSourceIDs, [])
        XCTAssertFalse(applyResult.pageIndexBuild.backlinkAudit.resolved.isEmpty)

        let updatedProjection = try XCTUnwrap(maintainer.projectionDocument(slug: "wiki/asktutor"))
        XCTAssertTrue(updatedProjection.bodyMD.contains("tutor-insight:candidate-apply"))
        XCTAssertTrue(updatedProjection.bodyMD.contains("reviewed, applied, rebuilt"))

        let readingContext = try await runtime.loadProjectionReadingContext(slug: "wiki/asktutor")
        XCTAssertEqual(readingContext.presentation.projection.slug, "wiki/asktutor")
        XCTAssertEqual(readingContext.runtimePackage.document.title, "ASK Tutor")
        XCTAssertEqual(readingContext.presentation.manifest.sourceIDs, ["ask-src-1"])
        XCTAssertEqual(readingContext.sourceCatalogs.count, 1)
        XCTAssertEqual(readingContext.sourceCatalogs.first?.askSourceID, "ask-src-1")
        XCTAssertFalse(readingContext.catalogEntries.isEmpty)
        XCTAssertFalse(readingContext.backlinkAudit.resolved.isEmpty)
        XCTAssertEqual(applyResult.presentation.manifest.bundleName, "wiki/asktutor")
    }

    func testKnowledgePipelinePostCommitFailureIsTypedAndKeepsCandidateForRetry() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = ASKProductWorkspacePaths(rootURL: rootURL)
        let maintainer = ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot)
        try maintainer.ensureKnowledgeBase()
        let pipeline = try ASKKnowledgePipeline(workspace: workspace, maintainer: maintainer)

        let candidate = try pipeline.captureStudyPlan(
            learnerID: "learner-post-commit",
            plan: TutorStudyPlan(
                learnerID: "learner-post-commit",
                generatedAt: "2026-04-13T11:00:00Z",
                headline: "Recover derived tutor outputs",
                focusTopics: ["Recovery"],
                actions: ["Retry the retained candidate with the same decision context"],
                rationale: ["Canonical knowledge and derived tutor outputs have different commit boundaries."],
                dueConceptIDs: [],
                knowledgeMaintenance: []
            ),
            candidateID: "candidate-post-commit-retry"
        )
        let proposal = try pipeline.buildProposal(candidateID: candidate.candidateID)

        // Replace the derived PageIndex directory with a file after pipeline
        // initialization. Canonical knowledge remains writable, but PageIndex
        // workspace creation must fail after the commit.
        try FileManager.default.removeItem(at: workspace.pageIndexRoot)
        try Data("blocked".utf8).write(to: workspace.pageIndexRoot)

        do {
            _ = try await pipeline.applyCandidate(
                candidateID: candidate.candidateID,
                decidedBy: "reviewer",
                decidedAt: "2026-04-13T11:01:00Z"
            )
            XCTFail("Expected typed TutorInsightPostCommitError")
        } catch let error as TutorInsightPostCommitError {
            XCTAssertEqual(error.failedEffect, .rebuildPageIndex)
            XCTAssertEqual(error.committedRecord.patchID, proposal.patch.patchID)
            XCTAssertFalse(error.cause.isEmpty)
        }

        let committed = try maintainer.snapshot()
        XCTAssertTrue(committed.approvedPatchIDs.contains(proposal.patch.patchID))
        XCTAssertNotNil(try pipeline.appliedStore.load(candidateID: candidate.candidateID))
        XCTAssertNotNil(try pipeline.candidateStore.load(candidateID: candidate.candidateID))

        try FileManager.default.removeItem(at: workspace.pageIndexRoot)
        try FileManager.default.createDirectory(at: workspace.pageIndexRoot, withIntermediateDirectories: true)

        let repaired = try await pipeline.applyCandidate(
            candidateID: candidate.candidateID,
            decidedBy: "reviewer",
            decidedAt: "2026-04-13T11:01:00Z"
        )
        XCTAssertEqual(repaired.record.patchID, proposal.patch.patchID)
        XCTAssertNil(try pipeline.candidateStore.load(candidateID: candidate.candidateID))
    }

    func testKnowledgePipelineBuildProposalCreatesFallbackProjectionForLearnerStudyPlan() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = ASKProductWorkspacePaths(rootURL: rootURL)
        let maintainer = ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot)
        try maintainer.ensureKnowledgeBase()

        let pipeline = try ASKKnowledgePipeline(
            workspace: workspace,
            maintainer: maintainer
        )
        let candidate = try pipeline.captureStudyPlan(
            learnerID: "learner-1",
            scope: nil,
            plan: TutorStudyPlan(
                learnerID: "learner-1",
                generatedAt: "2026-04-13T12:00:00Z",
                headline: "ASK grounding plan",
                focusTopics: ["Grounding"],
                actions: ["Review the truth boundary"],
                rationale: ["Keep Tutor read-oriented until review closes."],
                dueConceptIDs: ["ask.truth"],
                knowledgeMaintenance: []
            ),
            candidateID: "candidate-study-plan"
        )

        let proposal = try pipeline.buildProposal(candidateID: candidate.candidateID)
        let write = try XCTUnwrap(proposal.patch.projectionWrites.first)

        XCTAssertEqual(proposal.targetProjectionSlug, "queries/tutor-insights/learner-1/candidate-study-plan")
        XCTAssertEqual(write.document.slug, "queries/tutor-insights/learner-1/candidate-study-plan")
        XCTAssertEqual(write.document.metadata.subjectKind, "learner")
        XCTAssertEqual(write.document.metadata.subjectID, "learner-1")
        XCTAssertEqual(write.document.metadata.sourceIDs, [])
        XCTAssertTrue(write.document.bodyMD.contains("tutor-insight:candidate-study-plan"))
    }

    func testKnowledgePipelineBuildProposalMergesExistingProjectionWithoutDuplicatingAnchor() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = ASKProductWorkspacePaths(rootURL: rootURL)
        let maintainer = ASKRuntimeKnowledgeMaintainer(root: workspace.askRoot)
        try maintainer.ensureKnowledgeBase()

        let existingBody = """
# Existing projection

<!-- tutor-insight:candidate-merge -->

Existing anchored insight.
"""
        try seedProjectionKnowledge(
            rootURL: workspace.askRoot,
            slug: "wiki/asktutor",
            title: "ASK Tutor",
            body: existingBody,
            sourceIDs: ["ask-src-1"]
        )

        let pipeline = try ASKKnowledgePipeline(
            workspace: workspace,
            maintainer: maintainer
        )
        try pipeline.candidateStore.save(
            TutorInsightCandidate(
                candidateID: "candidate-merge",
                learnerID: "learner-1",
                sessionID: "session-1",
                createdAt: "2026-04-13T12:05:00Z",
                kind: .narrative,
                scope: .projection(slug: "wiki/asktutor"),
                primaryProjectionSlug: "wiki/asktutor",
                citationProjectionSlugs: ["wiki/asktutor"],
                sourceIDs: [" ask-src-1 ", "ask-src-2", ""],
                prompt: "Prompt",
                title: "New title should not replace existing projection title",
                summary: "Summary",
                bodyMarkdown: """
## New insight

Keep existing anchor stable.
""",
                evidence: [],
                relatedConceptIDs: [],
                suggestedActions: [.updateProjection],
                knowledgeGap: nil
            )
        )

        let proposal = try pipeline.buildProposal(candidateID: "candidate-merge")
        let write = try XCTUnwrap(proposal.patch.projectionWrites.first)

        XCTAssertEqual(proposal.targetProjectionSlug, "wiki/asktutor")
        XCTAssertEqual(write.document.title, "ASK Tutor")
        XCTAssertEqual(write.document.metadata.sourceIDs, ["ask-src-1", "ask-src-2"])
        XCTAssertEqual(write.document.bodyMD, existingBody)
    }

}
