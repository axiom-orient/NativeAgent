
enum TutorInsightSuggestedActionPolicies {
    static func make(
        primaryProjectionSlug: String?,
        includePracticeReview: Bool,
        includeStudyPlanReview: Bool
    ) -> [TutorInsightSuggestedAction] {
        var actions: [TutorInsightSuggestedAction] = [
            primaryProjectionSlug == nil ? .createProjection : .updateProjection,
            .reviewKnowledgeGap,
        ]
        if includePracticeReview {
            actions.append(.reviewPracticeWeaknesses)
        }
        if includeStudyPlanReview {
            actions.append(.reviewStudyPlan)
        }
        return actions
    }
}
