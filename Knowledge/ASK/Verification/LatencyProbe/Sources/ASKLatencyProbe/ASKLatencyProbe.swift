import ASK
import Foundation
import KnowledgeCore

/// Measures the phases named by the product-direction risk register
/// (import / search / cold relaunch replay) over a generated representative
/// corpus, using only the public root `ASK` facade so the same code runs on
/// macOS and iOS.
public struct LatencyProbeRun: Sendable {
    public struct Configuration: Sendable {
        public var documentCount: Int
        public var documentKilobytes: Int
        public var searchIterations: Int
        public var decisionMemorySeedCount: Int
        public var requestedAt: String

        public init(
            documentCount: Int = 250,
            documentKilobytes: Int = 12,
            searchIterations: Int = 25,
            decisionMemorySeedCount: Int = 10,
            requestedAt: String = "2026-08-24T00:00:00Z"
        ) {
            self.documentCount = documentCount
            self.documentKilobytes = documentKilobytes
            self.searchIterations = searchIterations
            self.decisionMemorySeedCount = decisionMemorySeedCount
            self.requestedAt = requestedAt
        }
    }

    public struct PhaseTiming: Codable, Sendable {
        public let phase: String
        public let seconds: Double
        public let detail: String?
    }

    public struct SearchSampleSet: Codable, Sendable {
        public let query: String
        public let iterations: Int
        public let p50Seconds: Double
        public let p95Seconds: Double
        public let maxSeconds: Double
        public let hitCount: Int
    }

    public struct Report: Codable, Sendable {
        public let schemaVersion: Int
        public let platform: String
        public let documentCount: Int
        public let documentKilobytes: Int
        public let corpusBytes: Int
        public let indexedCount: Int
        public let skippedCount: Int
        public let phases: [PhaseTiming]
        public let searches: [SearchSampleSet]
        public let totalSeconds: Double
    }

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Execution

    public func run(workspaceURL: URL) async throws -> Report {
        let started = Date()
        var phases: [PhaseTiming] = []
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        // The typed boundary requires the source root to live outside the
        // managed workspace, so the generated corpus becomes a sibling.
        let sourceRoot = workspaceURL.deletingLastPathComponent()
            .appendingPathComponent("ask-latency-corpus-\(UUID().uuidString)", isDirectory: true)

        let corpusBytes = try generateCorpus(at: sourceRoot)
        phases.append(PhaseTiming(phase: "corpusGeneration", seconds: Date().timeIntervalSince(started), detail: "\(corpusBytes) bytes"))

        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspaceURL))
        let probeQuery = "quarterly review checkpoint"
        let importPlan = try client.plan(.importWorkspace(ASKImportWorkspaceCommand(
            sourceRootURL: sourceRoot,
            title: "Latency probe corpus",
            queryText: probeQuery,
            requestedAt: configuration.requestedAt,
            maxEvidenceBytes: 32_000,
            resetExistingWorkspace: true
        )))
        _ = try client.dryRun(importPlan)

        var indexedCount = 0
        var skippedCount = 0
        let importStarted = Date()
        let outcome = try await client.apply(importPlan)
        if case .workspaceApplied(let result) = outcome {
            indexedCount = result.indexedCount
            skippedCount = result.skippedCount
        }
        phases.append(PhaseTiming(
            phase: "importWorkspace",
            seconds: Date().timeIntervalSince(importStarted),
            detail: "indexed \(indexedCount), skipped \(skippedCount)"
        ))

        var searches: [SearchSampleSet] = []
        searches.append(try await measureSearch(
            client, .searchEvidence(ASKEvidenceSearchQuery(text: probeQuery, limit: 20)),
            label: "searchEvidence", iterations: configuration.searchIterations
        ))
        searches.append(try await measureSearch(
            client, .searchKnowledge(ASKKnowledgeSearchQuery(text: probeQuery, limit: 20)),
            label: "searchKnowledge", iterations: configuration.searchIterations
        ))

        // Seed decision-memory facts through the public write contract, then
        // measure the deterministic context advisor.
        let seedStarted = Date()
        let records = (0..<configuration.decisionMemorySeedCount).map { index in
            MemoryRecord(
                recordID: String(format: "rec-probe-%04d", index),
                kind: .observation,
                subject: MemorySubject(kind: "study", subjectID: String(format: "subject-%04d", index)),
                scope: MemoryScope(workspaceID: "latency-probe"),
                statement: String(
                    format: "Probe observation %04d: quarterly review checkpoint retention note.",
                    index
                ),
                createdAt: configuration.requestedAt
            )
        }
        let dmPlan = try client.plan(.recordDecisionMemories(
            ASKRecordDecisionMemoriesCommand(records: records)
        ))
        _ = try await client.apply(dmPlan)
        phases.append(PhaseTiming(
            phase: "seedDecisionMemory",
            seconds: Date().timeIntervalSince(seedStarted),
            detail: "\(configuration.decisionMemorySeedCount) records in one journal pass"
        ))

        searches.append(try await measureSearch(
            client,
            .decisionMemory(ASKDecisionMemoryQuery(frame: TaskFrame(
                taskID: "probe-task",
                workspaceID: "latency-probe",
                requestedAt: configuration.requestedAt
            ))),
            label: "decisionMemory", iterations: max(3, configuration.searchIterations / 5)
        ))

        let healthStarted = Date()
        _ = try await client.query(.storageHealth(ASKStorageHealthQuery()))
        phases.append(PhaseTiming(phase: "storageHealthWarm", seconds: Date().timeIntervalSince(healthStarted), detail: nil))

        let pendingStarted = Date()
        _ = try await client.query(.pendingWork(ASKPendingWorkQuery()))
        phases.append(PhaseTiming(phase: "pendingWork", seconds: Date().timeIntervalSince(pendingStarted), detail: nil))

        // Cold relaunch: a fresh facade must rebuild runtime state from the
        // canonical journal before the first read can answer.
        let coldClient = ASKClient(configuration: ASKConfiguration(workspaceURL: workspaceURL))
        let coldStarted = Date()
        _ = try await coldClient.query(.storageHealth(ASKStorageHealthQuery()))
        phases.append(PhaseTiming(phase: "coldRelaunchFirstRead", seconds: Date().timeIntervalSince(coldStarted), detail: "journal replay + first read"))

        return Report(
            schemaVersion: 1,
            platform: currentPlatformIdentifier(),
            documentCount: configuration.documentCount,
            documentKilobytes: configuration.documentKilobytes,
            corpusBytes: corpusBytes,
            indexedCount: indexedCount,
            skippedCount: skippedCount,
            phases: phases,
            searches: searches,
            totalSeconds: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Corpus generation

    /// Generates markdown files with deterministic, varied vocabulary so
    /// evidence queries have stable hits without any external corpus.
    func generateCorpus(at root: URL) throws -> Int {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fillerWords = ["checkpoint", "ledger", "evidence", "review", "summary", "decision", "note"]
        var totalBytes = 0
        for index in 0..<configuration.documentCount {
            let targetBytes = configuration.documentKilobytes * 1_024
            var body = "# Document \(index): quarterly review checkpoint\n\n"
            body += "This note records the quarterly review checkpoint for subject \(index).\n\n"
            while body.utf8.count < targetBytes {
                for (offset, word) in fillerWords.enumerated() {
                    body += "Section \(body.utf8.count) mentions \(word)-\(index)-\(offset) in context. "
                    if body.utf8.count >= targetBytes { break }
                }
            }
            let fileURL = root.appendingPathComponent(String(format: "doc-%04d.md", index))
            try Data(body.utf8).write(to: fileURL, options: .atomic)
            totalBytes += body.utf8.count
        }
        return totalBytes
    }

    // MARK: - Measurement helpers

    private func measureSearch(
        _ client: ASKClient,
        _ query: ASKQuery,
        label: String,
        iterations: Int
    ) async throws -> SearchSampleSet {
        _ = try await client.query(query)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        var hitCount = 0
        for _ in 0..<iterations {
            let started = Date()
            let result = try await client.query(query)
            samples.append(Date().timeIntervalSince(started))
            if case .evidenceSearch(let payload) = result { hitCount = payload.items.count }
            if case .knowledgeSearch(let payload) = result { hitCount = payload.items.count }
        }
        let sorted = samples.sorted()
        return SearchSampleSet(
            query: label,
            iterations: iterations,
            p50Seconds: percentile(sorted, 0.50),
            p95Seconds: percentile(sorted, 0.95),
            maxSeconds: sorted.last ?? 0,
            hitCount: hitCount
        )
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((fraction * Double(sorted.count)).rounded(.down)))
        return sorted[index]
    }

    private func currentPlatformIdentifier() -> String {
        #if os(iOS)
        return "ios-\(ProcessInfo.processInfo.operatingSystemVersionString)"
        #elseif os(macOS)
        return "macos-\(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
