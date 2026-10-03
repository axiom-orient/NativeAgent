import Foundation
import KnowledgeCore
import KnowledgeRuntime

extension ASKIOSFMFKernel {
    public func planProjectionRemoval(slug: String, requestedAt: String, trigger: String = "manual_remove") throws -> KnowledgePatchPlan {
        try runtime.planProjectionRemoval(slug: slug, requestedAt: requestedAt, trigger: trigger)
    }

    public func removeProjection(
        slug: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        reason: String? = nil,
        trigger: String = "manual_remove"
    ) throws -> ASKApplySummary {
        try runtime.removeProjection(
            RemoveProjectionCommand(
                slug: slug,
                decision: RemoveProjectionCommand.DecisionContext(
                    requestedAt: requestedAt,
                    decidedBy: decidedBy,
                    decidedAt: decidedAt,
                    reason: reason,
                    trigger: trigger
                )
            )
        )
    }

    public func promoteSourceToWiki(
        sourceID: String,
        slug: String,
        title: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        bodySeed: String? = nil,
        trigger: String = "source_promote"
    ) throws -> ASKApplySummary {
        try runtime.promoteSourceToWiki(
            PromoteSourceCommand(
                sourceID: sourceID,
                slug: slug,
                title: title,
                bodySeed: bodySeed,
                decision: PromoteSourceCommand.DecisionContext(
                    requestedAt: requestedAt,
                    decidedBy: decidedBy,
                    decidedAt: decidedAt,
                    trigger: trigger
                )
            )
        )
    }

    public func compileSourceProjectionSet(
        sourceID: String,
        sourceSlug: String,
        sourceTitle: String,
        requestedAt: String,
        decidedBy: String,
        decidedAt: String,
        sourceBodySeed: String? = nil,
        related: [WikiProjectionSeed] = [],
        trigger: String = "source_projection_set_compile"
    ) throws -> ASKApplySummary {
        try runtime.compileSourceProjectionSet(
            CompileProjectionSetCommand(
                sourceID: sourceID,
                sourceSlug: sourceSlug,
                sourceTitle: sourceTitle,
                sourceBodySeed: sourceBodySeed,
                related: related,
                decision: CompileProjectionSetCommand.DecisionContext(
                    requestedAt: requestedAt,
                    decidedBy: decidedBy,
                    decidedAt: decidedAt,
                    trigger: trigger
                )
            )
        )
    }
}
