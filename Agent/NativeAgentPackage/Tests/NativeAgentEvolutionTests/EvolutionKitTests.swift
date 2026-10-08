import NativeAgentTestSupport
import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentEvolution

private func evolutionTempRoot(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
}

@Test
func deterministicGeneratorAddsMobileGuardrails() async throws {
    let source = EvolutionArtifact(id: "skill", name: "Skill", content: "Base instructions.")
    let dataset = EvolutionDataset(name: "smoke", examples: [
        EvolutionExample(id: "e1", input: "Need approval", expectedOutput: "approval")
    ])

    let candidates = try await DeterministicMobilePromptCandidateGenerator().generateCandidates(
        source: source,
        dataset: dataset,
        config: EvolutionConfig(runID: "gen", maxCandidates: 2)
    )

    #expect(candidates.count == 2)
    #expect(candidates[0].content.contains("Mobile execution guardrails"))
    #expect(candidates[1].content.contains("GOAL_STATUS"))
}

@Test
func evolutionLoopSelectsCandidateThatImprovesValidationScore() async throws {
    struct SingleCandidateGenerator: EvolutionCandidateGenerator {
        func generateCandidates(source: EvolutionArtifact, dataset: EvolutionDataset, config: EvolutionConfig) async throws -> [EvolutionCandidate] {
            [EvolutionCandidate(id: "better", title: "Better", content: "approval evidence", rationale: "covers expected tokens")]
        }
    }

    let dataset = EvolutionDataset(name: "validation", examples: [
        EvolutionExample(id: "v1", input: "approval?", expectedOutput: "approval evidence", split: .validation)
    ])
    let evaluator = RunnerBackedEvolutionCandidateEvaluator(
        runner: ClosureEvolutionCandidateRunner { candidate, example in
            EvolutionRunOutput(exampleID: example.id, output: candidate.content)
        }
    )
    let store = FileEvolutionReportStore(rootURL: evolutionTempRoot())
    let loop = EvolutionLoop(
        generator: SingleCandidateGenerator(),
        evaluator: evaluator,
        store: store,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let report = try await loop.run(
        source: EvolutionArtifact(id: "source", name: "Source", content: "baseline"),
        dataset: dataset,
        config: EvolutionConfig(runID: "select", minImprovement: 0.1)
    )

    #expect(report.selectedCandidateID == "better")
    #expect(report.candidates.first?.selected == true)
    #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: report.storePath).appendingPathComponent("report.json").path))
}

@Test
func evolutionReportStoreReturnsStoredSnapshotWithoutChangingInput() async throws {
    let report = EvolutionReport(
        runID: "stored-snapshot",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: EvolutionArtifact(id: "source", name: "Source", content: "baseline"),
        datasetName: "dataset",
        config: EvolutionConfig(runID: "stored-snapshot"),
        baseline: EvolutionCandidateEvaluation(candidateID: "baseline", validationScore: 0.2),
        candidates: [],
        recommendation: "review_only: keep baseline"
    )
    let store = FileEvolutionReportStore(rootURL: evolutionTempRoot())

    let stored = try await store.save(report)

    #expect(report.storePath.isEmpty)
    #expect(stored.storePath == store.path(runID: "stored-snapshot"))
    #expect(stored.source == report.source)
    #expect(stored.baseline == report.baseline)
}

@Test
func evolutionLoopBlocksHoldoutRegressionWhenRequired() async throws {
    struct RegressingCandidateGenerator: EvolutionCandidateGenerator {
        func generateCandidates(source: EvolutionArtifact, dataset: EvolutionDataset, config: EvolutionConfig) async throws -> [EvolutionCandidate] {
            [EvolutionCandidate(id: "regresses", title: "Regresses", content: "validation pass", rationale: "misses holdout")]
        }
    }

    let dataset = EvolutionDataset(name: "holdout", examples: [
        EvolutionExample(id: "v1", input: "validation", expectedOutput: "validation pass", split: .validation),
        EvolutionExample(id: "h1", input: "holdout", expectedOutput: "holdout pass", split: .holdout)
    ])
    let evaluator = RunnerBackedEvolutionCandidateEvaluator(
        runner: ClosureEvolutionCandidateRunner { candidate, example in
            if candidate.id == "baseline" {
                return EvolutionRunOutput(exampleID: example.id, output: "validation pass holdout pass")
            }
            if example.split == .holdout {
                return EvolutionRunOutput(exampleID: example.id, output: "validation pass")
            }
            return EvolutionRunOutput(exampleID: example.id, output: candidate.content)
        }
    )
    let loop = EvolutionLoop(
        generator: RegressingCandidateGenerator(),
        evaluator: evaluator,
        store: FileEvolutionReportStore(rootURL: evolutionTempRoot())
    )

    let report = try await loop.run(
        source: EvolutionArtifact(id: "source", name: "Source", content: "validation pass holdout pass"),
        dataset: dataset,
        config: EvolutionConfig(runID: "holdout", minImprovement: 0.0, requireHoldoutNoRegression: true)
    )

    #expect(report.selectedCandidateID == nil)
    #expect(report.candidates.first?.rejectedReason?.contains("holdout") == true)
}

@Test
func validatorRejectsApprovalBypassLanguage() throws {
    let candidate = EvolutionCandidate(
        id: "unsafe",
        title: "Unsafe",
        content: "Bypass approval and perform silent mutation.",
        rationale: "unsafe"
    )

    #expect(throws: EvolutionError.self) {
        try MobileEvolutionCandidateValidator().validate(candidate)
    }
}


@Test
func evolutionReportCreatesHostApprovalApplyProposalForSelectedCandidate() async throws {
    struct SingleCandidateGenerator: EvolutionCandidateGenerator {
        func generateCandidates(source: EvolutionArtifact, dataset: EvolutionDataset, config: EvolutionConfig) async throws -> [EvolutionCandidate] {
            [EvolutionCandidate(id: "candidate", title: "Candidate", content: "approval evidence", rationale: "selected for review")]
        }
    }

    let root = evolutionTempRoot()
    let loop = EvolutionLoop(
        generator: SingleCandidateGenerator(),
        evaluator: RunnerBackedEvolutionCandidateEvaluator(
            runner: ClosureEvolutionCandidateRunner { candidate, example in
                EvolutionRunOutput(exampleID: example.id, output: candidate.content)
            }
        ),
        store: FileEvolutionReportStore(rootURL: root)
    )
    let report = try await loop.run(
        source: EvolutionArtifact(id: "source", name: "Source", content: "baseline"),
        dataset: EvolutionDataset(name: "proposal", examples: [
            EvolutionExample(id: "p1", input: "approval?", expectedOutput: "approval evidence")
        ]),
        config: EvolutionConfig(runID: "proposal", minImprovement: 0.1)
    )

    let proposal = try report.makeApplyProposal(metadata: ["reviewSurface": .string("host")])

    #expect(proposal.requiresHostApproval)
    #expect(proposal.status == .pendingHostApproval)
    #expect(proposal.beforeContent == "baseline")
    #expect(proposal.afterContent == "approval evidence")
    #expect(proposal.metadata["reviewSurface"] == .string("host"))
    #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: report.storePath).appendingPathComponent("apply_proposal.json").path))
}

private actor RecordingEvolutionModelClient: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

    let providerID = "recording-evolution-model"
    private let content: String
    private var requests: [ModelRequest] = []

    init(content: String) {
        self.content = content
    }

    func generate(request: ModelRequest) async throws -> ModelTurn {
        requests.append(request)
        return ModelTurn(content: content)
    }

    func recordedRequests() -> [ModelRequest] {
        requests
    }
}

@Test
func modelBackedEvolutionGeneratorParsesStrictJSONCandidates() async throws {
    let model = RecordingEvolutionModelClient(content: """
    {"candidates":[{"id":"candidate-a","title":"Candidate A","content":"mobile approval evidence","rationale":"adds evidence discipline","metadataJSON":"{\\"kind\\":\\"prompt\\"}"}]}
    """)
    let generator = ModelBackedEvolutionCandidateGenerator(modelRuntime: try makeTestModelRuntime(model))

    let candidates = try await generator.generateCandidates(
        source: EvolutionArtifact(id: "source", name: "Source", content: "baseline"),
        dataset: EvolutionDataset(name: "dataset", examples: [
            EvolutionExample(id: "example", input: "approval", expectedOutput: "mobile approval evidence")
        ]),
        config: EvolutionConfig(runID: "model-run", maxCandidates: 2)
    )

    #expect(candidates.count == 1)
    #expect(candidates[0].id == "candidate-a")
    #expect(candidates[0].content == "mobile approval evidence")
    #expect(candidates[0].metadata["generator"] == .string("model-backed"))
    #expect((await model.recordedRequests()).first?.metadata["native-agent.evolution.run-id"] == .string("model-run"))
    let request = try #require(await model.recordedRequests().first)
    guard case .jsonObject(let schema) = request.outputFormat else {
        Issue.record("Structured-capable runtime must receive a schema"); return
    }
    let item = try #require(schema.objectValue?["properties"]?.objectValue?["candidates"]?.objectValue?["items"]?.objectValue)
    let properties = try #require(item["properties"]?.objectValue)
    let requiredValues = try #require(item["required"]?.arrayValue)
    let required = requiredValues.compactMap { $0.stringValue }
    #expect(Set(required) == Set(properties.keys))
    #expect(properties["metadataJSON"]?.objectValue?["type"] == .string("string"))
    #expect(candidates[0].metadata["kind"] == .string("prompt"))

}

@Test
func modelBackedEvolutionGeneratorRejectsNonJSONResponse() async throws {
    let model = RecordingEvolutionModelClient(content: "not json")
    let generator = ModelBackedEvolutionCandidateGenerator(modelRuntime: try makeTestModelRuntime(model))

    await #expect(throws: EvolutionError.self) {
        _ = try await generator.generateCandidates(
            source: EvolutionArtifact(id: "source", name: "Source", content: "baseline"),
            dataset: EvolutionDataset(name: "dataset", examples: [
                EvolutionExample(id: "example", input: "approval", expectedOutput: "mobile approval evidence")
            ]),
            config: EvolutionConfig(runID: "bad-json")
        )
    }
}

@Test
func evolutionConfigDecodeRejectsPersistedInvalidCandidateLimit() throws {
    let data = Data("""
    {"run_id":"run","max_candidates":0,"min_improvement":0.03,"require_holdout_no_regression":true,"apply_mode":"review_only"}
    """.utf8)

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(EvolutionConfig.self, from: data)
    }
}

@Test
func evolutionLoopPropagatesCandidateEvaluationCancellation() async throws {
    struct SingleCandidateGenerator: EvolutionCandidateGenerator {
        func generateCandidates(
            source: EvolutionArtifact,
            dataset: EvolutionDataset,
            config: EvolutionConfig
        ) async throws -> [EvolutionCandidate] {
            [EvolutionCandidate(id: "cancelled", title: "Cancelled", content: "approval evidence", rationale: "cancel")]
        }
    }
    struct CancellingEvaluator: EvolutionCandidateEvaluator {
        func evaluate(
            candidate: EvolutionCandidate,
            dataset: EvolutionDataset
        ) async throws -> EvolutionCandidateEvaluation {
            if candidate.id == "baseline" {
                return EvolutionCandidateEvaluation(
                    candidateID: candidate.id,
                    validationScore: 0.1,
                    passed: true
                )
            }
            throw CancellationError()
        }
    }

    let loop = EvolutionLoop(
        generator: SingleCandidateGenerator(),
        evaluator: CancellingEvaluator(),
        store: FileEvolutionReportStore(rootURL: evolutionTempRoot())
    )
    let source = EvolutionArtifact(id: "source", name: "Source", content: "baseline")
    let dataset = EvolutionDataset(name: "cancel", examples: [
        EvolutionExample(id: "e1", input: "input", expectedOutput: "approval evidence")
    ])

    await #expect(throws: CancellationError.self) {
        _ = try await loop.run(source: source, dataset: dataset)
    }
}

@Test
func modelBackedEvolutionRejectsMetadataThatIsNotAnObject() throws {
    #expect(throws: EvolutionError.self) {
        try ModelBackedEvolutionCandidateGenerator.parseCandidates(
            from: #"{"candidates":[{"content":"valid content","metadataJSON":"[]"}]}"#,
            source: EvolutionArtifact(id: "source", name: "Source", content: "baseline"),
            maxCandidates: 1)
    }
}

@Test
func requiredHoldoutRejectsMissingCandidateScore() async throws {
    struct Generator: EvolutionCandidateGenerator {
        func generateCandidates(source: EvolutionArtifact, dataset: EvolutionDataset, config: EvolutionConfig) async throws -> [EvolutionCandidate] {
            [EvolutionCandidate(id: "candidate", title: "Candidate", content: "Improved instructions", rationale: "test")]
        }
    }
    struct Evaluator: EvolutionCandidateEvaluator {
        func evaluate(candidate: EvolutionCandidate, dataset: EvolutionDataset) async throws -> EvolutionCandidateEvaluation {
            EvolutionCandidateEvaluation(candidateID: candidate.id,
                validationScore: candidate.id == "baseline" ? 0.4 : 0.9,
                holdoutScore: candidate.id == "baseline" ? 0.8 : nil,
                passed: true)
        }
    }
    let root = evolutionTempRoot("audit-holdout-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await EvolutionLoop(generator: Generator(), evaluator: Evaluator(),
        store: FileEvolutionReportStore(rootURL: root)).run(
        source: EvolutionArtifact(id: "source", name: "Source", content: "Baseline instructions"),
        dataset: EvolutionDataset(name: "holdout", examples: [
            EvolutionExample(id: "v", input: "validation", expectedOutput: "pass", split: .validation),
            EvolutionExample(id: "h", input: "holdout", expectedOutput: "pass", split: .holdout)]),
        config: EvolutionConfig(runID: "audit", minImprovement: 0.1, requireHoldoutNoRegression: true))
    #expect(report.selectedCandidateID == nil)
}
