import ASKApplication
import Foundation
import KnowledgeCore
import KnowledgeRuntime
import WorkWiki

extension ASKClient {
    func applyTypedValidated(_ plan: ASKCommandPlan, maintenanceLease: ASKApplicationMutationLease? = nil) async throws -> ASKApplyOutcome {
        try Task.checkCancellation()
        try ASKManagedRouteContainment.verify(plan, configuration: configuration)
        let applicationConfiguration = ASKApplicationConfiguration(
            vaultURL: plan.context.vaultURL,
            evidenceIndexURL: plan.context.indexURL
        )
        if let maintenanceLease {
            guard maintenanceLease.configuration == applicationConfiguration,
                  await application.isActiveMutation(maintenanceLease, protecting: plan.mutationRoots) else {
                throw mutationLeaseDiagnostic(actionID: plan.actionID)
            }
            return try await execute(plan)
        }
        let lease = try await application.beginMutation(
            actionID: plan.actionID,
            configuration: applicationConfiguration,
            additionalProtectedRoots: plan.mutationRoots
        )

        let result: Result<ASKApplyOutcome, Error>
        do { result = .success(try await execute(plan)) }
        catch { result = .failure(error) }
        guard await application.finishMutation(lease) else {
            if case .failure(let error) = result {
                let primary = mapASKDiagnostic(error, operation: .apply)
                throw ASKDiagnostic(
                    code: .conflict,
                    operation: .apply,
                    message: "The operation failed and its mutation lease could not be released",
                    context: [
                        "actionID": plan.actionID,
                        "primaryError": primary.message,
                    ],
                    recovery: .inspectStorage
                )
            }
            throw mutationLeaseDiagnostic(actionID: plan.actionID)
        }
        return try result.get()
    }

    private func execute(_ plan: ASKCommandPlan) async throws -> ASKApplyOutcome {
        // Acquisition can suspend. A cancelled waiter must not start effects.
        try Task.checkCancellation()
        switch plan.command {
        case .quickStart(let command):
            return try await quickStart(command, plan: plan)
        case .indexWorkspace(let command):
            return try await indexWorkspace(command, plan: plan)
        case .importWorkspace(let command):
            return try await importWorkspace(command, plan: plan)
        case .stageReport(let command):
            return try await stageReport(command, plan: plan)
        case .closeDay(let command):
            return try await closeDay(command, plan: plan)
        case .importCapture(let command):
            return try await importCapture(command, plan: plan)
        case .decidePatch(let command):
            return try await decidePatch(command, plan: plan)
        case .repairPresentation(let command):
            return try repairPresentation(command, plan: plan)
        case .rebuildKnowledge(let command):
            return try rebuildKnowledge(command, plan: plan)
        case .recordDecisionMemory(let command):
            return try await recordDecisionMemory(command, plan: plan)
        case .recordDecisionMemories(let command):
            return try await recordDecisionMemories(command, plan: plan)
        case .transitionDecisionMemory(let command):
            return try await transitionDecisionMemory(command, plan: plan)
        case .consolidateDecisionMemory(let command):
            return try await consolidateDecisionMemory(command, plan: plan)
        }
    }

    private func quickStart(
        _ command: ASKQuickStartCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let canonicalRuntime = ASKRuntime(root: plan.context.vaultURL)
        let before = try canonicalRuntime.snapshot()
        do {
            let result = try await ASKWorkWikiQuickStartRunner().run(
                ASKWorkWikiQuickStartRequest(
                    workspaceURL: plan.context.workspaceURL,
                    requestedAt: command.requestedAt,
                    indexURL: plan.context.indexURL,
                    vaultURL: plan.context.vaultURL,
                    decidedBy: command.decidedBy,
                    reason: command.reason,
                    resetExistingWorkspace: command.resetExistingWorkspace
                )
            )
            let committed = ASKWorkspaceApplyResult(
                actionID: plan.actionID,
                workspaceURL: URL(fileURLWithPath: result.workspacePath, isDirectory: true),
                sourceRootURL: URL(fileURLWithPath: result.sourceRootPath, isDirectory: true),
                indexURL: URL(fileURLWithPath: result.indexPath, isDirectory: true),
                vaultURL: URL(fileURLWithPath: result.vaultPath, isDirectory: true),
                publishedProjectionURL: result.publishedProjectionPath.map { URL(fileURLWithPath: $0) },
                indexedCount: result.indexedCount,
                skippedCount: 0,
                evidenceHitCount: result.evidenceHitCount,
                remainingPendingPatchCount: result.remainingPendingPatchIDs.count,
                patchID: result.patchID,
                projectionSlug: result.projectionSlug,
                title: result.publishedProjectionTitle,
                decision: try patchDecision(result.applyDecision),
                preview: result.publishedProjectionPreview
            )
            return finalizePresentation(
                committed: .workspace(committed),
                projectionSlugs: [result.projectionSlug],
                context: plan.context,
                createdAt: command.requestedAt
            )
        } catch {
            let probe = probeCommittedOutcome(
                after: error,
                plan: plan,
                before: before,
                runtime: canonicalRuntime,
                expectedPatchID: nil,
                requestedDecision: .approved
            )
            if let outcome = probe.outcome { return outcome }
            if !probe.inspected {
                throw unknownOutcomeDiagnostic(
                    error,
                    actionID: plan.actionID,
                    inspectionFailure: probe.inspectionFailure
                )
            }
            throw error
        }
    }

    private func indexWorkspace(
        _ command: ASKIndexWorkspaceCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let result = try await ASKWorkWikiQuickStartRunner().indexSources(
            ASKWorkWikiIndexSourcesRequest(
                sourceRootURL: command.sourceRootURL,
                indexURL: plan.context.indexURL
            )
        )
        return .sourcesIndexed(ASKSourceIndexResult(
            actionID: plan.actionID,
            sourceRootURL: result.sourceRootURL,
            indexURL: result.indexURL,
            indexedSourceIDs: result.indexedSourceIDs,
            indexedPaths: result.indexedPaths,
            skippedCount: result.skippedSources.count
        ))
    }

    private func importWorkspace(
        _ command: ASKImportWorkspaceCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let canonicalRuntime = ASKRuntime(root: plan.context.vaultURL)
        let before = try canonicalRuntime.snapshot()
        do {
            let result = try await ASKWorkWikiQuickStartRunner().runFromExistingWorkspace(
                ASKWorkWikiFromExistingWorkspaceRequest(
                    sourceRootURL: command.sourceRootURL,
                    workspaceURL: plan.context.workspaceURL,
                    title: command.title,
                    queryText: command.queryText,
                    requestedAt: command.requestedAt,
                    indexURL: plan.context.indexURL,
                    vaultURL: plan.context.vaultURL,
                    decidedBy: command.decidedBy,
                    reason: command.reason,
                    slug: command.slug,
                    subjectID: command.subjectID,
                    maxEvidenceBytes: command.maxEvidenceBytes,
                    includeStaleEvidence: command.includeStaleEvidence,
                    resetExistingWorkspace: command.resetExistingWorkspace
                )
            )
            let committed = ASKWorkspaceApplyResult(
                actionID: plan.actionID,
                workspaceURL: URL(fileURLWithPath: result.workspacePath, isDirectory: true),
                sourceRootURL: URL(fileURLWithPath: result.sourceRootPath, isDirectory: true),
                indexURL: URL(fileURLWithPath: result.indexPath, isDirectory: true),
                vaultURL: URL(fileURLWithPath: result.vaultPath, isDirectory: true),
                publishedProjectionURL: result.publishedProjectionPath.map { URL(fileURLWithPath: $0) },
                indexedCount: result.indexedCount,
                skippedCount: result.skippedCount,
                evidenceHitCount: result.evidenceHitCount,
                remainingPendingPatchCount: result.remainingPendingPatchIDs.count,
                patchID: result.patchID,
                projectionSlug: result.projectionSlug,
                title: result.publishedProjectionTitle,
                decision: try patchDecision(result.applyDecision),
                preview: result.publishedProjectionPreview
            )
            return finalizePresentation(
                committed: .workspace(committed),
                projectionSlugs: [result.projectionSlug],
                context: plan.context,
                createdAt: command.requestedAt
            )
        } catch {
            let probe = probeCommittedOutcome(
                after: error,
                plan: plan,
                before: before,
                runtime: canonicalRuntime,
                expectedPatchID: nil,
                requestedDecision: .approved
            )
            if let outcome = probe.outcome { return outcome }
            if !probe.inspected {
                throw unknownOutcomeDiagnostic(
                    error,
                    actionID: plan.actionID,
                    inspectionFailure: probe.inspectionFailure
                )
            }
            throw error
        }
    }

    private func stageReport(
        _ command: ASKStageReportCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let runtime = try await workWikiRuntime(context: plan.context)
        let report = try await runtime.stageReport(
            ASKWorkWikiReportRequest(
                title: command.title,
                queryText: command.queryText,
                requestedAt: command.requestedAt,
                slug: command.slug,
                subjectID: command.subjectID,
                maxEvidenceBytes: command.maxEvidenceBytes,
                includeStaleEvidence: command.includeStaleEvidence
            )
        )
        return .staged(.report(ASKReportStagedResult(
            actionID: plan.actionID,
            patchID: report.patch.patchID,
            projectionSlug: report.projectionWrite.slug,
            evidenceHitCount: report.evidencePack.hits.count
        )))
    }

    private func closeDay(
        _ command: ASKCloseDayCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let runtime = try await workWikiRuntime(context: plan.context)
        let value = try await runtime.closeDay(
            ASKWorkWikiCloseDayRequest(
                date: command.date,
                queryText: command.queryText,
                requestedAt: command.requestedAt,
                slug: command.slug,
                subjectID: command.subjectID,
                maxEvidenceBytes: command.maxEvidenceBytes,
                includeStaleEvidence: command.includeStaleEvidence
            )
        )
        return .staged(.closeDay(ASKCloseDayStagedResult(
            actionID: plan.actionID,
            patchID: value.patch.patchID,
            projectionSlug: value.projectionWrite.slug,
            evidenceHitCount: value.evidencePack.hits.count,
            doneCount: value.summary.done.count,
            blockerCount: value.summary.blockers.count
        )))
    }

    private func importCapture(
        _ command: ASKImportCaptureCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let runtime = try await workWikiRuntime(context: plan.context)
        let value = try await runtime.captureEvidence(
            ASKWorkWikiCaptureRequest(
                captureManifestPath: command.captureManifestURL,
                domain: command.domain,
                requestedAt: command.requestedAt,
                focusPrompt: command.focusPrompt
            )
        )
        return .staged(.capture(ASKCaptureStagedResult(
            actionID: plan.actionID,
            patchID: value.patch.patchID,
            sourceID: value.importedCapture.sourceID,
            rawURL: URL(fileURLWithPath: value.importedCapture.rawPath)
        )))
    }

    private func decidePatch(
        _ command: ASKDecidePatchCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let canonicalRuntime = ASKRuntime(root: plan.context.vaultURL)
        let before = try canonicalRuntime.snapshot()
        let wasPending = before.pendingPatchIDs.contains(command.patchID)
        do {
            if let direct = try directDecisionPatch(command.patchID, vaultURL: plan.context.vaultURL) {
                return .decided(try applyDirectDecision(command, patch: direct, actionID: plan.actionID, vaultURL: plan.context.vaultURL))
            }

            let runtime = try await workWikiRuntime(context: plan.context)
            switch command.decision {
            case .approved:
                let approval = try await runtime.approveReport(
                    ASKWorkWikiReportApprovalRequest(
                        patchID: command.patchID,
                        decidedBy: command.decidedBy,
                        decidedAt: command.decidedAt,
                        reason: command.reason,
                        requireFreshEvidence: command.requireFreshEvidence
                    )
                )
                let committed = ASKPatchDecisionResult(
                    actionID: plan.actionID,
                    patchID: approval.patch.patchID,
                    decision: .approved,
                    remainingPendingPatchCount: approval.applySummary.rebuild.pendingPatchIDs.count
                )
                return finalizePresentation(
                    committed: .decision(committed),
                    projectionSlugs: approval.patch.projectionWrites.map(\.slug),
                    context: plan.context,
                    createdAt: command.decidedAt
                )
            case .rejected:
                let rejection = try await runtime.rejectReport(
                    ASKWorkWikiReportRejectionRequest(
                        patchID: command.patchID,
                        decidedBy: command.decidedBy,
                        decidedAt: command.decidedAt,
                        reason: command.reason
                    )
                )
                return .decided(ASKPatchDecisionResult(
                    actionID: plan.actionID,
                    patchID: rejection.patch.patchID,
                    decision: .rejected,
                    remainingPendingPatchCount: rejection.applySummary.rebuild.pendingPatchIDs.count
                ))
            }
        } catch {
            if wasPending {
                let probe = probeCommittedOutcome(
                    after: error,
                    plan: plan,
                    before: before,
                    runtime: canonicalRuntime,
                    expectedPatchID: command.patchID,
                    requestedDecision: command.decision
                )
                if let outcome = probe.outcome { return outcome }
                if !probe.inspected {
                    throw unknownOutcomeDiagnostic(
                        error,
                        actionID: plan.actionID,
                        patchID: command.patchID,
                        inspectionFailure: probe.inspectionFailure
                    )
                }
            }
            throw error
        }
    }

    private func rebuildKnowledge(
        _ command: ASKRebuildKnowledgeCommand,
        plan: ASKCommandPlan
    ) throws -> ASKApplyOutcome {
        let summary = try ASKRuntime(root: plan.context.vaultURL).rebuild()
        return .knowledgeRebuilt(ASKKnowledgeRebuildResult(
            actionID: plan.actionID,
            approvedPatchIDs: summary.approvedPatchIDs,
            rejectedPatchIDs: summary.rejectedPatchIDs,
            pendingPatchIDs: summary.pendingPatchIDs,
            mirrorCounts: summary.mirrorCounts
        ))
    }

    private func repairPresentation(
        _ command: ASKRepairPresentationCommand,
        plan: ASKCommandPlan
    ) throws -> ASKApplyOutcome {
        try ASKPresentationRepairTokenFactory.verify(command.token)
        guard command.token.knowledgeRootURL == plan.context.vaultURL,
              command.token.productWorkspaceURL == plan.context.productWorkspaceURL else {
            throw ASKDiagnostic(
                code: .integrityViolation,
                operation: .repair,
                message: "Repair token routes do not match the command plan",
                context: ["tokenID": command.token.id],
                recovery: .correctInput
            )
        }

        let store = ASKPresentationRepairStore(productWorkspaceURL: command.token.productWorkspaceURL)
        let existing = try store.load(token: command.token)
        if existing?.state == .completed {
            return .presentationRepaired(ASKPresentationRepairResult(
                actionID: plan.actionID,
                token: command.token,
                materializedProjectionCount: command.token.projectionSlugs.count,
                alreadyCompleted: true
            ))
        }

        do {
            try ASKProjectionPresentationMaterializer.materialize(
                slugs: command.token.projectionSlugs,
                knowledgeRootURL: command.token.knowledgeRootURL,
                productWorkspaceURL: command.token.productWorkspaceURL
            )
        } catch {
            let diagnostic = derivedOutputDiagnostic(
                error,
                actionID: command.token.actionID,
                tokenID: command.token.id
            )
            let pending = ASKPresentationRepairRecord(
                token: command.token,
                committed: existing?.committed,
                diagnostic: diagnostic,
                state: .pending
            )
            do {
                try store.save(pending)
            } catch {
                throw ASKDiagnostic(
                    code: .storageFailure,
                    operation: .repair,
                    message: "Presentation repair failed and its pending record could not be persisted",
                    context: [
                        "tokenID": command.token.id,
                        "materializationError": diagnostic.message,
                        "persistenceError": String(describing: error),
                    ],
                    recovery: .inspectStorage
                )
            }
            throw diagnostic
        }

        try store.save(ASKPresentationRepairRecord(
            token: command.token,
            committed: existing?.committed,
            diagnostic: nil,
            state: .completed,
            completedAt: command.requestedAt
        ))
        return .presentationRepaired(ASKPresentationRepairResult(
            actionID: plan.actionID,
            token: command.token,
            materializedProjectionCount: command.token.projectionSlugs.count,
            alreadyCompleted: false
        ))
    }

    private func recordDecisionMemory(
        _ command: ASKRecordDecisionMemoryCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let state = try await ASKWorkWikiDecisionMemoryJournal(
            decisionMemoryRootURL: plan.context.vaultURL
        ).append(command.record)
        return .decisionMemory(ASKDecisionMemoryMutationResult(
            actionID: plan.actionID,
            kind: .record,
            generation: state.generation,
            recordCount: state.recordCount,
            transitionCount: state.transitionCount
        ))
    }

    private func recordDecisionMemories(
        _ command: ASKRecordDecisionMemoriesCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let state = try await ASKWorkWikiDecisionMemoryJournal(
            decisionMemoryRootURL: plan.context.vaultURL
        ).append(command.records)
        return .decisionMemory(ASKDecisionMemoryMutationResult(
            actionID: plan.actionID,
            kind: .record,
            generation: state.generation,
            recordCount: state.recordCount,
            transitionCount: state.transitionCount
        ))
    }

    private func transitionDecisionMemory(
        _ command: ASKTransitionDecisionMemoryCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let journal = ASKWorkWikiDecisionMemoryJournal(
            decisionMemoryRootURL: plan.context.vaultURL
        )
        let isReplay = try await journal.containsIdenticalTransition(command.transition)
        if !isReplay && (command.transition.kind == .verify || command.transition.kind == .promote) {
            let snapshot = try await journal.snapshot(asOf: command.transition.occurredAt)
            if let current = snapshot.state(recordID: command.transition.recordID) {
                let refs = current.evidenceRefs + (command.transition.kind == .verify ? command.transition.evidenceRefs : [])
                try await ASKDecisionMemoryEvidence.requireCurrent(recordID: current.record.recordID,
                    refs: refs, indexURL: plan.context.indexURL)
            }
        }
        let state = try await journal.append(command.transition)
        return .decisionMemory(ASKDecisionMemoryMutationResult(
            actionID: plan.actionID,
            kind: .transition,
            generation: state.generation,
            recordCount: state.recordCount,
            transitionCount: state.transitionCount
        ))
    }

    private func consolidateDecisionMemory(
        _ command: ASKConsolidateDecisionMemoryCommand,
        plan: ASKCommandPlan
    ) async throws -> ASKApplyOutcome {
        let consolidation = try await ASKWorkWikiDecisionMemoryJournal(
            decisionMemoryRootURL: plan.context.vaultURL
        ).consolidate(asOf: command.asOf)
        return .decisionMemory(ASKDecisionMemoryMutationResult(
            actionID: plan.actionID,
            kind: .consolidate,
            generation: consolidation.state.generation,
            recordCount: consolidation.state.recordCount,
            transitionCount: consolidation.state.transitionCount,
            materializedFiles: consolidation.files
        ))
    }

    private func finalizePresentation(
        committed: ASKCommittedValue,
        projectionSlugs: [String],
        context: ASKPlanContext,
        createdAt: String
    ) -> ASKApplyOutcome {
        let normal = normalOutcome(committed)
        let slugs = Array(Set(projectionSlugs)).sorted()
        guard !slugs.isEmpty else { return normal }

        do {
            try ASKProjectionPresentationMaterializer.materialize(
                slugs: slugs,
                knowledgeRootURL: context.vaultURL,
                productWorkspaceURL: context.productWorkspaceURL
            )
            return normal
        } catch {
            let token = ASKPresentationRepairTokenFactory.make(
                actionID: committed.actionID,
                knowledgeRootURL: context.vaultURL,
                productWorkspaceURL: context.productWorkspaceURL,
                projectionSlugs: slugs,
                createdAt: createdAt
            )

            var diagnostic = derivedOutputDiagnostic(error, actionID: committed.actionID, tokenID: token.id)
            let record = ASKPresentationRepairRecord(
                token: token,
                committed: committed,
                diagnostic: diagnostic,
                state: .pending
            )
            do {
                try ASKPresentationRepairStore(productWorkspaceURL: context.productWorkspaceURL).save(record)
            } catch {
                diagnostic = ASKDiagnostic(
                    code: .storageFailure,
                    operation: .repair,
                    message: "Canonical commit succeeded, presentation materialization failed, and the repair record could not be persisted",
                    context: [
                        "actionID": committed.actionID,
                        "tokenID": token.id,
                        "materializationError": diagnostic.message,
                        "persistenceError": String(describing: error),
                    ],
                    recovery: .inspectStorage
                )
            }
            return .committedWithRepairRequired(
                committed,
                ASKRepairRequirement(token: token, diagnostic: diagnostic)
            )
        }
    }

    private func normalOutcome(_ committed: ASKCommittedValue) -> ASKApplyOutcome {
        switch committed {
        case .workspace(let value): .workspaceApplied(value)
        case .decision(let value): .decided(value)
        }
    }

    private func workWikiRuntime(context: ASKPlanContext) async throws -> ASKWorkWikiRuntime {
        try await application.workWikiRuntime(
            configuration: ASKApplicationConfiguration(
                vaultURL: context.vaultURL,
                evidenceIndexURL: context.indexURL
            )
        )
    }

    /// Returns the patch when its decision belongs to the direct runtime route.
    ///
    /// Routing follows the declared `patchKind`. Inferring it from an empty
    /// `projectionWrites` array misread two cases: an authority registration legitimately
    /// writes no projection, and a projection refresh whose writes were all blocked ends
    /// up empty and would then skip the workflow that owns it.
    private func directDecisionPatch(_ patchID: String, vaultURL: URL) throws -> KnowledgePatchPlan? {
        let pending = try ASKRuntimeKnowledgeMaintainer(root: vaultURL).pendingPatchPlans()
        guard let patch = pending.first(where: { $0.patchID == patchID }) else { return nil }
        switch patch.patchKind {
        case .evidenceIngest, .authorityRegister:
            return patch
        case .projectionRefresh:
            return nil
        }
    }

    private func applyDirectDecision(
        _ command: ASKDecidePatchCommand,
        patch: KnowledgePatchPlan,
        actionID: String,
        vaultURL: URL
    ) throws -> ASKPatchDecisionResult {
        let runtime = ASKRuntime(root: vaultURL)
        let domainDecision: PatchDecision = command.decision == .approved ? .approved : .rejected
        let receipt = try runtime.buildReceipt(
            for: patch,
            decision: domainDecision,
            decidedBy: command.decidedBy,
            decidedAt: command.decidedAt,
            reason: command.reason
        )
        let summary = try runtime.apply(patch, receipt)
        return ASKPatchDecisionResult(
            actionID: actionID,
            patchID: patch.patchID,
            decision: command.decision,
            remainingPendingPatchCount: summary.rebuild.pendingPatchIDs.count
        )
    }

    private func patchDecision(_ value: String) throws -> ASKPatchDecision {
        switch value {
        case "approved", "applied": .approved
        case "rejected": .rejected
        default:
            throw ASKDiagnostic(
                code: .integrityViolation,
                operation: .apply,
                message: "Unexpected patch decision: \(value)",
                context: ["decision": value],
                recovery: .inspectStorage
            )
        }
    }

    private func mutationLeaseDiagnostic(actionID: String) -> ASKDiagnostic {
        ASKDiagnostic(
            code: .conflict,
            operation: .apply,
            message: "Mutation lease ownership was lost before completion",
            context: ["actionID": actionID],
            recovery: .inspectStorage
        )
    }

    private func derivedOutputDiagnostic(
        _ error: Error,
        actionID: String,
        tokenID: String
    ) -> ASKDiagnostic {
        ASKDiagnostic(
            code: .derivedOutputFailure,
            operation: .repair,
            message: "Canonical knowledge commit succeeded, but derived presentation materialization failed",
            context: [
                "actionID": actionID,
                "tokenID": tokenID,
                "underlying": String(describing: error),
            ],
            recovery: .repairDerivedOutput
        )
    }

    private func probeCommittedOutcome(
        after error: Error,
        plan: ASKCommandPlan,
        before: ASKStateSnapshot,
        runtime: ASKRuntime,
        expectedPatchID: String?,
        requestedDecision: ASKPatchDecision
    ) -> (outcome: ASKApplyOutcome?, inspected: Bool, inspectionFailure: String?) {
        if let committedError = error as? ASKPostCommitMaterializationError {
            let actualDecision: ASKPatchDecision = committedError.decision == .approved ? .approved : .rejected
            let diagnostic = ASKDiagnostic(
                code: .partialEffect,
                operation: .apply,
                message: "Canonical state committed, but derived materialization failed",
                context: [
                    "actionID": plan.actionID,
                    "patchID": committedError.patchID,
                    "requestedDecision": requestedDecision.rawValue,
                    "actualDecision": actualDecision.rawValue,
                    "underlying": committedError.cause,
                ],
                recovery: .rebuildStorage
            )
            return (.committedWithRecoveryRequired(ASKCommittedRecoveryResult(
                actionID: plan.actionID,
                patchID: committedError.patchID,
                decision: actualDecision,
                diagnostic: diagnostic
            )), true, nil)
        }
        let snapshot: ASKStateSnapshot
        do {
            snapshot = try runtime.snapshot()
        } catch {
            return (nil, false, String(describing: error))
        }

        let beforeApproved = Set(before.approvedPatchIDs)
        let beforeRejected = Set(before.rejectedPatchIDs)
        let candidates: [(String, ASKPatchDecision)]
        if let expectedPatchID {
            if snapshot.approvedPatchIDs.contains(expectedPatchID) {
                candidates = [(expectedPatchID, .approved)]
            } else if snapshot.rejectedPatchIDs.contains(expectedPatchID) {
                candidates = [(expectedPatchID, .rejected)]
            } else {
                candidates = []
            }
        } else {
            let approved = snapshot.approvedPatchIDs
                .filter { !beforeApproved.contains($0) }
                .map { ($0, ASKPatchDecision.approved) }
            let rejected = snapshot.rejectedPatchIDs
                .filter { !beforeRejected.contains($0) }
                .map { ($0, ASKPatchDecision.rejected) }
            candidates = approved + rejected
        }

        guard candidates.count == 1, let committed = candidates.first else {
            return (nil, true, nil)
        }

        let diagnostic = ASKDiagnostic(
            code: .partialEffect,
            operation: .apply,
            message: "Canonical state committed, but a later materialization effect failed",
            context: [
                "actionID": plan.actionID,
                "patchID": committed.0,
                "requestedDecision": requestedDecision.rawValue,
                "actualDecision": committed.1.rawValue,
                "underlying": String(describing: error),
            ],
            recovery: .rebuildStorage
        )
        return (.committedWithRecoveryRequired(ASKCommittedRecoveryResult(
            actionID: plan.actionID,
            patchID: committed.0,
            decision: committed.1,
            diagnostic: diagnostic
        )), true, nil)
    }

    private func unknownOutcomeDiagnostic(
        _ error: Error,
        actionID: String,
        patchID: String? = nil,
        inspectionFailure: String? = nil
    ) -> ASKDiagnostic {
        var context = [
            "actionID": actionID,
            "underlying": String(describing: error),
        ]
        if let patchID { context["patchID"] = patchID }
        if let inspectionFailure { context["outcomeInspectionFailure"] = inspectionFailure }
        return ASKDiagnostic(
            code: .unknownOutcome,
            operation: .apply,
            message: "The effect failed and canonical commit state could not be inspected",
            context: context,
            recovery: .inspectOperation
        )
    }

}

private extension ASKCommittedValue {
    var actionID: String {
        switch self {
        case .workspace(let value): value.actionID
        case .decision(let value): value.actionID
        }
    }
}
