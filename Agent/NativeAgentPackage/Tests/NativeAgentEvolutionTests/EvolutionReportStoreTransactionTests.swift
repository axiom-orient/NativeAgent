import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentEvolution

private func reportCandidate(
    id: String = "candidate",
    selected: Bool = true
) -> EvolutionCandidateReport {
    EvolutionCandidateReport(
        candidate: EvolutionCandidate(
            id: id,
            title: "Candidate",
            content: "candidate content",
            rationale: "test"
        ),
        evaluation: EvolutionCandidateEvaluation(
            candidateID: id,
            validationScore: 0.8
        ),
        selected: selected
    )
}

private func reportFixture(
    runID: String,
    candidates: [EvolutionCandidateReport] = [],
    selectedCandidateID: String? = nil,
    recommendation: String = "review"
) -> EvolutionReport {
    EvolutionReport(
        runID: runID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: EvolutionArtifact(
            id: "source",
            name: "Source",
            content: "baseline"
        ),
        datasetName: "dataset",
        config: EvolutionConfig(runID: runID),
        baseline: EvolutionCandidateEvaluation(
            candidateID: "baseline",
            validationScore: 0.2
        ),
        candidates: candidates,
        selectedCandidateID: selectedCandidateID,
        recommendation: recommendation
    )
}

@Test
func evolutionReportPlannerRejectsInvalidSelectionBeforeFilesystemEffects() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let store = FileEvolutionReportStore(rootURL: root)
    let report = reportFixture(
        runID: "invalid-selection",
        candidates: [reportCandidate(id: "real-candidate", selected: false)],
        selectedCandidateID: "missing-candidate"
    )

    await #expect(throws: EvolutionError.self) {
        _ = try await store.save(report)
    }

    #expect(!fileManager.fileExists(atPath: root.path))
    #expect(!fileManager.fileExists(atPath: store.path(runID: report.runID)))
}

@Test
func evolutionReportReplacementRemovesStaleApplyProposal() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let store = FileEvolutionReportStore(rootURL: root)
    let selected = reportFixture(
        runID: "replace-snapshot",
        candidates: [reportCandidate()],
        selectedCandidateID: "candidate"
    )
    _ = try await store.save(selected)
    let directory = URL(fileURLWithPath: store.path(runID: selected.runID), isDirectory: true)
    #expect(fileManager.fileExists(
        atPath: directory.appendingPathComponent("apply_proposal.json").path
    ))

    let replacement = reportFixture(
        runID: "replace-snapshot",
        candidates: [],
        selectedCandidateID: nil,
        recommendation: "keep baseline"
    )
    let stored = try await store.save(replacement)

    #expect(stored.recommendation == "keep baseline")
    #expect(!fileManager.fileExists(
        atPath: directory.appendingPathComponent("apply_proposal.json").path
    ))
    #expect(!fileManager.fileExists(
        atPath: root.appendingPathComponent(".replace-snapshot.transaction").path
    ))
}

@Test
func evolutionReportTransactionReducerRejectsInvalidTransitions() throws {
    let reducer = EvolutionReportTransactionReducer()
    #expect(
        try reducer.reduce(phase: .prepared, action: .previousBackedUp)
            == .previousBackedUp
    )
    #expect(
        try reducer.reduce(phase: .previousBackedUp, action: .committed)
            == .committed
    )
    #expect(throws: EvolutionError.self) {
        _ = try reducer.reduce(phase: .prepared, action: .committed)
    }
}

@Test
func evolutionReportTransactionRecoveryRestoresPreviousDirectory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let runID = "recover-report"
    let transactionRoot = root.appendingPathComponent(".\(runID).transaction", isDirectory: true)
    let backup = transactionRoot.appendingPathComponent("backup", isDirectory: true)
    try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
    try "previous".write(
        to: backup.appendingPathComponent("report.json"),
        atomically: true,
        encoding: .utf8
    )
    let journal = EvolutionReportTransactionJournal(
        runID: runID,
        phase: .previousBackedUp,
        hadPreviousDirectory: true
    )
    try JSONEncoder.nativeAgent(sortedKeys: true).encode(journal).write(
        to: transactionRoot.appendingPathComponent("journal.json"),
        options: .atomic
    )

    try EvolutionReportDirectoryTransaction(
        rootURL: root,
        fileManager: fileManager
    ).recoverIfNeeded(runID: runID)

    let destination = root.appendingPathComponent(runID, isDirectory: true)
    #expect(
        try String(
            contentsOf: destination.appendingPathComponent("report.json"),
            encoding: .utf8
        ) == "previous"
    )
    #expect(!fileManager.fileExists(atPath: transactionRoot.path))
}
