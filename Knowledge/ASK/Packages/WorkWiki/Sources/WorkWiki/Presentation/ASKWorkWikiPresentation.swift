import Foundation

public struct ASKWorkWikiPresentationMetric: Codable, Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct ASKWorkWikiPresentationAction: Codable, Equatable, Sendable {
    public var label: String
    public var instruction: String

    public init(label: String, instruction: String) {
        self.label = label
        self.instruction = instruction
    }
}

public struct ASKWorkWikiPresentationSection: Codable, Equatable, Sendable {
    public var title: String
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

public struct ASKWorkWikiFromExistingWorkspacePresentationModel: Codable, Equatable, Sendable {
    public var title: String
    public var status: String
    public var summary: String
    public var metrics: [ASKWorkWikiPresentationMetric]
    public var sections: [ASKWorkWikiPresentationSection]
    public var primaryAction: ASKWorkWikiPresentationAction?
    public var secondaryActions: [ASKWorkWikiPresentationAction]
    public var publishedProjectionPath: String?

    public init(
        title: String,
        status: String,
        summary: String,
        metrics: [ASKWorkWikiPresentationMetric],
        sections: [ASKWorkWikiPresentationSection],
        primaryAction: ASKWorkWikiPresentationAction?,
        secondaryActions: [ASKWorkWikiPresentationAction],
        publishedProjectionPath: String?
    ) {
        self.title = title
        self.status = status
        self.summary = summary
        self.metrics = metrics
        self.sections = sections
        self.primaryAction = primaryAction
        self.secondaryActions = secondaryActions
        self.publishedProjectionPath = publishedProjectionPath
    }
}

public enum ASKWorkWikiFromExistingWorkspacePresentationExtension {
    public static func makePresentationModel(from result: ASKWorkWikiFromExistingWorkspaceResult) -> ASKWorkWikiFromExistingWorkspacePresentationModel {
        let actions = result.followUpActions.map(makeAction)
        let primary = actions.first { $0.label == "Read published projection" } ?? actions.first
        let secondary = actions.filter { $0 != primary }

        var sections: [ASKWorkWikiPresentationSection] = [
            ASKWorkWikiPresentationSection(title: "Published projection", lines: [result.publishedProjectionPath ?? "No projection path was returned"]),
            ASKWorkWikiPresentationSection(title: "Preview", lines: result.publishedProjectionPreview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        ]

        if !result.indexedPaths.isEmpty {
            sections.append(ASKWorkWikiPresentationSection(title: "Indexed sources", lines: result.indexedPaths))
        }
        if !result.skippedSources.isEmpty {
            sections.append(ASKWorkWikiPresentationSection(title: "Skipped sources", lines: result.skippedSources.map { "\($0.path) — \($0.reason)" }))
        }

        return ASKWorkWikiFromExistingWorkspacePresentationModel(
            title: result.reportTitle,
            status: result.status,
            summary: "Indexed \(result.indexedCount) source(s), applied patch \(result.patchID), and published \(result.projectionSlug).",
            metrics: [
                ASKWorkWikiPresentationMetric(label: "Indexed", value: String(result.indexedCount)),
                ASKWorkWikiPresentationMetric(label: "Skipped", value: String(result.skippedCount)),
                ASKWorkWikiPresentationMetric(label: "Evidence hits", value: String(result.evidenceHitCount)),
                ASKWorkWikiPresentationMetric(label: "Pending patches", value: String(result.remainingPendingPatchIDs.count))
            ],
            sections: sections,
            primaryAction: primary,
            secondaryActions: secondary,
            publishedProjectionPath: result.publishedProjectionPath
        )
    }

    private static func makeAction(from instruction: String) -> ASKWorkWikiPresentationAction {
        if instruction.hasPrefix("read published projection") { return ASKWorkWikiPresentationAction(label: "Read published projection", instruction: instruction) }
        if instruction.hasPrefix("read evidenceSearch") { return ASKWorkWikiPresentationAction(label: "Search indexed evidence", instruction: instruction) }
        if instruction.hasPrefix("read storageHealth") { return ASKWorkWikiPresentationAction(label: "Check storage health", instruction: instruction) }
        return ASKWorkWikiPresentationAction(label: "Review action", instruction: instruction)
    }
}
