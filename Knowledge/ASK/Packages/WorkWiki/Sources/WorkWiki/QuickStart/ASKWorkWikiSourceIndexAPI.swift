import Foundation

public struct ASKWorkWikiIndexSourcesRequest: Sendable, Equatable {
    public let sourceRootURL: URL
    public let indexURL: URL

    public init(sourceRootURL: URL, indexURL: URL) {
        self.sourceRootURL = sourceRootURL.standardizedFileURL
        self.indexURL = indexURL.standardizedFileURL
    }
}

public struct ASKWorkWikiIndexSourcesResult: Codable, Sendable, Equatable {
    public let sourceRootURL: URL
    public let indexURL: URL
    public let indexedSourceIDs: [String]
    public let indexedPaths: [String]
    public let skippedSources: [ASKWorkWikiSkippedSource]

    public init(
        sourceRootURL: URL,
        indexURL: URL,
        indexedSourceIDs: [String],
        indexedPaths: [String],
        skippedSources: [ASKWorkWikiSkippedSource]
    ) {
        self.sourceRootURL = sourceRootURL
        self.indexURL = indexURL
        self.indexedSourceIDs = indexedSourceIDs
        self.indexedPaths = indexedPaths
        self.skippedSources = skippedSources
    }
}

public extension ASKWorkWikiQuickStartRunner {
    /// Indexes source bytes without staging or approving knowledge. This is the
    /// composable ingestion primitive used by agent/iPhone review workflows.
    func indexSources(
        _ request: ASKWorkWikiIndexSourcesRequest
    ) async throws -> ASKWorkWikiIndexSourcesResult {
        let sourceRootURL = request.sourceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let indexURL = request.indexURL.standardizedFileURL.resolvingSymlinksInPath()
        let indexed = try await indexSourceFiles(sourceRootURL: sourceRootURL, indexURL: indexURL)
        guard !indexed.sourceIDs.isEmpty || indexed.skippedSources.isEmpty else {
            let skippedSummary = indexed.skippedSources.isEmpty
                ? "no markdown or PDF source files found"
                : "all discovered source files were skipped"
            throw ASKWorkWikiError(
                .noIndexableSources,
                "index-sources requires at least one indexed markdown or PDF source; \(skippedSummary)"
            )
        }
        return ASKWorkWikiIndexSourcesResult(
            sourceRootURL: sourceRootURL,
            indexURL: indexURL,
            indexedSourceIDs: indexed.sourceIDs.map(\.rawValue).sorted(),
            indexedPaths: indexed.indexedPaths,
            skippedSources: indexed.skippedSources
        )
    }
}
