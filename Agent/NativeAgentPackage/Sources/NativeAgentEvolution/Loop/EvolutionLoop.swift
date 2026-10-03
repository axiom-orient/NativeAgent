import Foundation

public struct EvolutionLoop: Sendable {
    private let generator: any EvolutionCandidateGenerator
    private let evaluator: any EvolutionCandidateEvaluator
    private let store: any EvolutionReportStore
    private let validator: MobileEvolutionCandidateValidator
    private let now: @Sendable () -> Date

    public init(
        generator: any EvolutionCandidateGenerator,
        evaluator: any EvolutionCandidateEvaluator,
        store: any EvolutionReportStore,
        validator: MobileEvolutionCandidateValidator = MobileEvolutionCandidateValidator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.generator = generator
        self.evaluator = evaluator
        self.store = store
        self.validator = validator
        self.now = now
    }

    public func run(
        source: EvolutionArtifact,
        dataset: EvolutionDataset,
        config: EvolutionConfig = EvolutionConfig()
    ) async throws -> EvolutionReport {
        guard !source.content.trimmedForNativeAgentEvolution.isEmpty else { throw EvolutionError.emptySource }
        guard !dataset.examples.isEmpty else { throw EvolutionError.emptyDataset }

        let baselineCandidate = EvolutionCandidate(
            id: "baseline",
            title: "Baseline",
            content: source.content,
            rationale: "current source artifact"
        )
        try Task.checkCancellation()
        let baseline = try await evaluator.evaluate(candidate: baselineCandidate, dataset: dataset)
        try Task.checkCancellation()
        let generated = try await generator.generateCandidates(source: source, dataset: dataset, config: config)
        try Task.checkCancellation()
        let limited = Array(generated.prefix(config.maxCandidates))
        guard !limited.isEmpty else { throw EvolutionError.noCandidates }

        var reports: [EvolutionCandidateReport] = []
        for candidate in limited {
            do {
                try Task.checkCancellation()
                try validator.validate(candidate)
                let evaluation = try await evaluator.evaluate(candidate: candidate, dataset: dataset)
                try Task.checkCancellation()
                reports.append(
                    EvolutionCandidateReport(
                        candidate: candidate,
                        evaluation: evaluation,
                        selected: false,
                        rejectedReason: nil
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let failedEvaluation = EvolutionCandidateEvaluation(
                    candidateID: candidate.id,
                    validationScore: 0,
                    holdoutScore: nil,
                    exampleScores: [],
                    passed: false,
                    reason: error.localizedDescription
                )
                reports.append(
                    EvolutionCandidateReport(
                        candidate: candidate,
                        evaluation: failedEvaluation,
                        selected: false,
                        rejectedReason: error.localizedDescription
                    )
                )
            }
        }

        let selectedID = selectedCandidateID(
            baseline: baseline,
            candidates: reports,
            config: config
        )
        reports = finalizedReports(
            reports,
            selectedID: selectedID,
            baseline: baseline,
            config: config
        )

        let recommendation: String
        if let selectedID {
            recommendation = "review_only: candidate \"\(selectedID)\" improved validation score and should be reviewed by the host/user before application"
        } else {
            recommendation = "review_only: no candidate cleared improvement and holdout gates; keep baseline"
        }

        try Task.checkCancellation()
        let report = EvolutionReport(
            runID: config.runID,
            createdAt: now(),
            source: source,
            datasetName: dataset.name,
            config: config,
            baseline: baseline,
            candidates: reports,
            selectedCandidateID: selectedID,
            recommendation: recommendation,
            storePath: store.path(runID: config.runID)
        )
        let stored = try await store.save(report)
        try Task.checkCancellation()
        return stored
    }

    private func selectedCandidateID(
        baseline: EvolutionCandidateEvaluation,
        candidates: [EvolutionCandidateReport],
        config: EvolutionConfig
    ) -> String? {
        let eligible = candidates.filter { report in
            guard report.evaluation.passed else { return false }
            guard report.evaluation.validationScore >= baseline.validationScore + config.minImprovement else { return false }
            if config.requireHoldoutNoRegression,
               let baselineHoldout = baseline.holdoutScore {
                guard let candidateHoldout = report.evaluation.holdoutScore,
                      candidateHoldout + EvolutionConfig.holdoutRegressionTolerance >= baselineHoldout else {
                    return false
                }
            }
            return true
        }
        return eligible.max(by: { lhs, rhs in
            lhs.evaluation.validationScore < rhs.evaluation.validationScore
        })?.candidate.id
    }

    private func finalizedReports(
        _ reports: [EvolutionCandidateReport],
        selectedID: String?,
        baseline: EvolutionCandidateEvaluation,
        config: EvolutionConfig
    ) -> [EvolutionCandidateReport] {
        reports.map { report in
            let selected = report.candidate.id == selectedID
            let rejectedReason = selected
                ? report.rejectedReason
                : report.rejectedReason ?? rejectionReason(baseline: baseline, report: report, config: config)
            return EvolutionCandidateReport(
                candidate: report.candidate,
                evaluation: report.evaluation,
                selected: selected,
                rejectedReason: rejectedReason
            )
        }
    }

    private func rejectionReason(
        baseline: EvolutionCandidateEvaluation,
        report: EvolutionCandidateReport,
        config: EvolutionConfig
    ) -> String {
        if !report.evaluation.passed { return report.evaluation.reason.isEmpty ? "candidate evaluation failed" : report.evaluation.reason }
        if report.evaluation.validationScore < baseline.validationScore + config.minImprovement {
            return String(format: "validation improvement %.3f is below minImprovement %.3f", report.evaluation.validationScore - baseline.validationScore, config.minImprovement)
        }
        if config.requireHoldoutNoRegression,
           let baselineHoldout = baseline.holdoutScore {
            guard let candidateHoldout = report.evaluation.holdoutScore else {
                return "required holdout evaluation is missing"
            }
            if candidateHoldout + EvolutionConfig.holdoutRegressionTolerance < baselineHoldout {
                return String(format: "holdout score regressed from %.3f to %.3f", baselineHoldout, candidateHoldout)
            }
        }
        return "not selected"
    }
}
