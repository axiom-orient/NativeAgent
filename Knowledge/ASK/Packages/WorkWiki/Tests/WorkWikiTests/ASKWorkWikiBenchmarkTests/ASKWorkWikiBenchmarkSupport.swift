import Foundation
@testable import WorkWiki

public struct ASKWorkWikiLargeWorkspaceBenchmarkRequest: Sendable, Equatable {
    public var workspaceURL: URL
    public var documentCount: Int
    public var requestedAt: String
    public var resetExistingWorkspace: Bool
    public var baselineURL: URL?

    public init(
        workspaceURL: URL,
        documentCount: Int = 250,
        requestedAt: String = "2026-04-20T10:00:00Z",
        resetExistingWorkspace: Bool = false,
        baselineURL: URL? = nil
    ) {
        self.workspaceURL = workspaceURL
        self.documentCount = documentCount
        self.requestedAt = requestedAt
        self.resetExistingWorkspace = resetExistingWorkspace
        self.baselineURL = baselineURL
    }
}

public struct ASKWorkWikiBenchmarkBaseline: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var documentCount: Int
    public var minimumIndexedCount: Int
    public var maximumSkippedCount: Int
    public var minimumEvidenceHitCount: Int
    public var maximumWorkflowSeconds: Double
    public var maximumTotalSeconds: Double

    public init(
        schemaVersion: Int = 1,
        documentCount: Int,
        minimumIndexedCount: Int,
        maximumSkippedCount: Int,
        minimumEvidenceHitCount: Int,
        maximumWorkflowSeconds: Double,
        maximumTotalSeconds: Double
    ) {
        self.schemaVersion = schemaVersion
        self.documentCount = documentCount
        self.minimumIndexedCount = minimumIndexedCount
        self.maximumSkippedCount = maximumSkippedCount
        self.minimumEvidenceHitCount = minimumEvidenceHitCount
        self.maximumWorkflowSeconds = maximumWorkflowSeconds
        self.maximumTotalSeconds = maximumTotalSeconds
    }
}

public struct ASKWorkWikiBenchmarkRegressionReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var baselinePath: String
    public var failures: [String]

    public init(ok: Bool, baselinePath: String, failures: [String]) {
        self.ok = ok
        self.baselinePath = baselinePath
        self.failures = failures
    }
}

public struct ASKWorkWikiBenchmarkDurations: Codable, Sendable, Equatable {
    public var generationSeconds: Double
    public var workflowSeconds: Double
    public var totalSeconds: Double

    public init(generationSeconds: Double, workflowSeconds: Double, totalSeconds: Double) {
        self.generationSeconds = generationSeconds
        self.workflowSeconds = workflowSeconds
        self.totalSeconds = totalSeconds
    }
}

public struct ASKWorkWikiLargeWorkspaceBenchmarkResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var operation: String
    public var workspacePath: String
    public var sourceRootPath: String
    public var documentCount: Int
    public var bytesWritten: Int
    public var indexedCount: Int
    public var skippedCount: Int
    public var evidenceHitCount: Int
    public var patchID: String
    public var projectionSlug: String
    public var publishedProjectionPath: String?
    public var durations: ASKWorkWikiBenchmarkDurations
    public var regression: ASKWorkWikiBenchmarkRegressionReport?
    public var followUpActions: [String]

    public init(
        ok: Bool,
        operation: String,
        workspacePath: String,
        sourceRootPath: String,
        documentCount: Int,
        bytesWritten: Int,
        indexedCount: Int,
        skippedCount: Int,
        evidenceHitCount: Int,
        patchID: String,
        projectionSlug: String,
        publishedProjectionPath: String?,
        durations: ASKWorkWikiBenchmarkDurations,
        regression: ASKWorkWikiBenchmarkRegressionReport? = nil,
        followUpActions: [String]
    ) {
        self.ok = ok
        self.operation = operation
        self.workspacePath = workspacePath
        self.sourceRootPath = sourceRootPath
        self.documentCount = documentCount
        self.bytesWritten = bytesWritten
        self.indexedCount = indexedCount
        self.skippedCount = skippedCount
        self.evidenceHitCount = evidenceHitCount
        self.patchID = patchID
        self.projectionSlug = projectionSlug
        self.publishedProjectionPath = publishedProjectionPath
        self.durations = durations
        self.regression = regression
        self.followUpActions = followUpActions
    }
}

public struct ASKWorkWikiLargeWorkspaceBenchmarkRunner: Sendable {
    public init() {}

    public func run(_ request: ASKWorkWikiLargeWorkspaceBenchmarkRequest) async throws -> ASKWorkWikiLargeWorkspaceBenchmarkResult {
        try validate(request)
        let totalStart = Date()
        let workspaceURL = request.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        try prepareWorkspace(workspaceURL, reset: request.resetExistingWorkspace)
        let sourceRootURL = workspaceURL.appendingPathComponent("source", isDirectory: true)
        let generated = try writeSyntheticWorkspace(sourceRootURL: sourceRootURL, count: request.documentCount, updatedAt: request.requestedAt)
        let generationSeconds = Date().timeIntervalSince(totalStart)

        let workflowStart = Date()
        let result = try await ASKWorkWikiQuickStartRunner().runFromExistingWorkspace(
            ASKWorkWikiFromExistingWorkspaceRequest(
                sourceRootURL: sourceRootURL,
                workspaceURL: workspaceURL.appendingPathComponent("generated", isDirectory: true),
                title: "Large Workspace Benchmark Report",
                queryText: "benchmark latency shipping blocker",
                requestedAt: request.requestedAt,
                decidedBy: "benchmark",
                reason: "large workspace benchmark approval",
                slug: "work/reports/large-workspace-benchmark",
                subjectID: "large-workspace-benchmark",
                resetExistingWorkspace: true
            )
        )
        let workflowSeconds = Date().timeIntervalSince(workflowStart)
        let totalSeconds = Date().timeIntervalSince(totalStart)

        var benchmarkResult = ASKWorkWikiLargeWorkspaceBenchmarkResult(
            ok: true,
            operation: "benchmark-large-workspace",
            workspacePath: workspaceURL.path,
            sourceRootPath: sourceRootURL.path,
            documentCount: request.documentCount,
            bytesWritten: generated.bytesWritten,
            indexedCount: result.indexedCount,
            skippedCount: result.skippedCount,
            evidenceHitCount: result.evidenceHitCount,
            patchID: result.patchID,
            projectionSlug: result.projectionSlug,
            publishedProjectionPath: result.publishedProjectionPath,
            durations: ASKWorkWikiBenchmarkDurations(generationSeconds: generationSeconds, workflowSeconds: workflowSeconds, totalSeconds: totalSeconds),
            followUpActions: result.followUpActions
        )

        if let baselineURL = request.baselineURL {
            let regression = try evaluateBaseline(at: baselineURL, against: benchmarkResult)
            guard regression.ok else {
                throw ASKWorkWikiError(
                    .benchmarkRegressionFailed,
                    "benchmark result failed baseline thresholds",
                    context: ["baselinePath": baselineURL.path, "failures": regression.failures.joined(separator: "; ")]
                )
            }
            benchmarkResult.regression = regression
        }

        return benchmarkResult
    }

    private func validate(_ request: ASKWorkWikiLargeWorkspaceBenchmarkRequest) throws {
        guard !request.workspaceURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKWorkWikiError(.invalidRequest, "benchmark-large-workspace workspaceURL must not be empty", context: ["field": "workspaceURL"])
        }
        guard request.documentCount > 0 else {
            throw ASKWorkWikiError(.invalidRequest, "benchmark-large-workspace documentCount must be positive", context: ["field": "documentCount"])
        }
    }

    private func evaluateBaseline(
        at baselineURL: URL,
        against result: ASKWorkWikiLargeWorkspaceBenchmarkResult
    ) throws -> ASKWorkWikiBenchmarkRegressionReport {
        let data: Data
        do {
            data = try Data(contentsOf: baselineURL)
        } catch {
            throw ASKWorkWikiError(.benchmarkRegressionFailed, "failed to read benchmark baseline", context: ["baselinePath": baselineURL.path, "cause": String(describing: error)])
        }

        let baseline: ASKWorkWikiBenchmarkBaseline
        do {
            baseline = try JSONDecoder().decode(ASKWorkWikiBenchmarkBaseline.self, from: data)
        } catch {
            throw ASKWorkWikiError(.benchmarkRegressionFailed, "failed to decode benchmark baseline", context: ["baselinePath": baselineURL.path, "cause": String(describing: error)])
        }

        var failures: [String] = []
        if baseline.schemaVersion != 1 { failures.append("unsupported schemaVersion \(baseline.schemaVersion)") }
        if result.documentCount != baseline.documentCount { failures.append("documentCount \(result.documentCount) != baseline \(baseline.documentCount)") }
        if result.indexedCount < baseline.minimumIndexedCount { failures.append("indexedCount \(result.indexedCount) < minimum \(baseline.minimumIndexedCount)") }
        if result.skippedCount > baseline.maximumSkippedCount { failures.append("skippedCount \(result.skippedCount) > maximum \(baseline.maximumSkippedCount)") }
        if result.evidenceHitCount < baseline.minimumEvidenceHitCount { failures.append("evidenceHitCount \(result.evidenceHitCount) < minimum \(baseline.minimumEvidenceHitCount)") }
        if result.durations.workflowSeconds > baseline.maximumWorkflowSeconds { failures.append("workflowSeconds \(result.durations.workflowSeconds) > maximum \(baseline.maximumWorkflowSeconds)") }
        if result.durations.totalSeconds > baseline.maximumTotalSeconds { failures.append("totalSeconds \(result.durations.totalSeconds) > maximum \(baseline.maximumTotalSeconds)") }

        return ASKWorkWikiBenchmarkRegressionReport(ok: failures.isEmpty, baselinePath: baselineURL.path, failures: failures)
    }

    private func prepareWorkspace(_ workspaceURL: URL, reset: Bool) throws {
        try prepareWorkWikiWorkspace(workspaceURL, reset: reset)
    }

    private func writeSyntheticWorkspace(sourceRootURL: URL, count: Int, updatedAt: String) throws -> GeneratedBenchmarkWorkspace {
        var bytesWritten = 0
        for index in 1...count {
            let shard = String(format: "%03d", ((index - 1) / 100) + 1)
            let fileURL = sourceRootURL.appendingPathComponent("work/shard-\(shard)", isDirectory: true).appendingPathComponent(String(format: "day-%04d.md", index))
            let markdown = syntheticDocument(index: index, updatedAt: updatedAt)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            bytesWritten += Data(markdown.utf8).count
        }
        return GeneratedBenchmarkWorkspace(bytesWritten: bytesWritten)
    }

    private func syntheticDocument(index: Int, updatedAt: String) -> String {
        """
        ---
        scope: work
        kind: worklog
        topic: benchmark
        status: active
        updated_at: \(updatedAt)
        tags: [benchmark, latency]
        ---
        # Benchmark Work Log \(index)

        ## Done
        - Recorded benchmark latency evidence for source-backed report generation.
        - Tracked shipping blocker state for synthetic workspace item \(index).

        ## Decision
        - Keep the benchmark path headless and SwiftPM-native.

        ## Next
        - Inspect generated projection and evidence hits.
        """
    }
}

private struct GeneratedBenchmarkWorkspace: Sendable, Equatable {
    var bytesWritten: Int
}
