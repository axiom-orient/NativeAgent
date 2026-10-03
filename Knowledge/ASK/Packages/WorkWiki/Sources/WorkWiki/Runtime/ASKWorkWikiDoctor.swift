import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public enum ASKWorkWikiDoctor {
    public static func findings(
        request: ASKWorkWikiDoctorRequest,
        maintainer: any ASKKnowledgeMaintainer,
        evidenceIndex: ASKEvidenceIndex
    ) async throws -> [ASKWorkWikiDoctorFinding] {
        var findings: [ASKWorkWikiDoctorFinding] = []

        if request.includeASKLint {
            findings.append(contentsOf: try askLintFindings(from: maintainer.lint()))
        }

        if request.checkEvidenceFreshness {
            findings.append(contentsOf: try await evidenceFreshnessFindings(request: request, evidenceIndex: evidenceIndex))
        }

        if request.checkIndexedReports {
            findings.append(contentsOf: try await indexedDocumentFindings(request: request, evidenceIndex: evidenceIndex))
        }

        if request.checkPendingPatches {
            findings.append(contentsOf: try await pendingPatchFindings(maintainer: maintainer, evidenceIndex: evidenceIndex))
        }

        return sortedFindings(findings)
    }

    public static func storageHealthFindings(_ report: ASKStorageHealthReport) -> [ASKWorkWikiDoctorFinding] {
        report.derivedFreshness.compactMap { freshness in
            guard freshness.state != .healthy else { return nil }
            let severity: String
            switch freshness.state {
            case .missing, .corrupt:
                severity = "error"
            case .stale:
                severity = "warning"
            case .healthy:
                severity = "info"
            }
            let actual = freshness.actualGeneration.map(String.init) ?? "nil"
            return ASKWorkWikiDoctorFinding(
                kind: "storage_\(freshness.component.rawValue)_\(freshness.state.rawValue)",
                severity: severity,
                count: 1,
                items: ["expected=\(freshness.expectedGeneration) actual=\(actual)"]
            )
        }
    }

    public static func sortedFindings(_ findings: [ASKWorkWikiDoctorFinding]) -> [ASKWorkWikiDoctorFinding] {
        findings.sorted { lhs, rhs in
            let lRank = severityRank(lhs.severity)
            let rRank = severityRank(rhs.severity)
            if lRank != rRank { return lRank > rRank }
            return lhs.kind < rhs.kind
        }
    }

    private static func askLintFindings(from report: LintResult) throws -> [ASKWorkWikiDoctorFinding] {
        report.findings.map { finding in
            ASKWorkWikiDoctorFinding(
                kind: "ask_lint.\(finding.kind)",
                severity: normalizeSeverity(finding.severity),
                count: finding.count,
                items: finding.items ?? []
            )
        }
    }

    private static func evidenceFreshnessFindings(
        request: ASKWorkWikiDoctorRequest,
        evidenceIndex: ASKEvidenceIndex
    ) async throws -> [ASKWorkWikiDoctorFinding] {
        let statuses: [ASKEvidenceDocumentStatus]
        do {
            statuses = try await evidenceIndex.freshnessReport(filter: request.evidenceFilter)
        } catch {
            throw ASKWorkWikiError(.freshnessCheckFailed, "failed to build evidence freshness report", context: ["cause": String(describing: error)])
        }
        let stale = statuses.filter { $0.freshness == .stale }.map(statusItem).sorted()
        let missing = statuses.filter { $0.freshness == .missing }.map(statusItem).sorted()

        var findings: [ASKWorkWikiDoctorFinding] = []
        if !missing.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "evidence_source_missing", severity: "error", count: missing.count, items: missing))
        }
        if !stale.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "evidence_source_stale", severity: "warning", count: stale.count, items: stale))
        }
        return findings
    }

    private static func indexedDocumentFindings(
        request: ASKWorkWikiDoctorRequest,
        evidenceIndex: ASKEvidenceIndex
    ) async throws -> [ASKWorkWikiDoctorFinding] {
        var findings: [ASKWorkWikiDoctorFinding] = []

        var reportFilter = request.evidenceFilter
        reportFilter.kinds = [.report]
        let reports: [ASKEvidenceMetadata]
        do {
            reports = try await evidenceIndex.listDocuments(filter: reportFilter)
        } catch {
            throw ASKWorkWikiError(.sourceIndexFailed, "failed to list indexed report documents", context: ["cause": String(describing: error)])
        }
        let reportsMissingSourceRefs = reports
            .filter { $0.sourceRefs.isEmpty }
            .map(documentItem)
            .sorted()
        if !reportsMissingSourceRefs.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "indexed_report_missing_source_refs", severity: "error", count: reportsMissingSourceRefs.count, items: reportsMissingSourceRefs))
        }

        var docsFilter = request.evidenceFilter
        docsFilter.kinds = [.docs]
        let docs: [ASKEvidenceMetadata]
        do {
            docs = try await evidenceIndex.listDocuments(filter: docsFilter)
        } catch {
            throw ASKWorkWikiError(.sourceIndexFailed, "failed to list indexed docs documents", context: ["cause": String(describing: error)])
        }
        let docsMissingSourceRefs = docs
            .filter { $0.sourceRefs.isEmpty }
            .map(documentItem)
            .sorted()
        if !docsMissingSourceRefs.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "indexed_docs_missing_source_refs", severity: "error", count: docsMissingSourceRefs.count, items: docsMissingSourceRefs))
        }

        return findings
    }

    private static func pendingPatchFindings(
        maintainer: any ASKKnowledgeMaintainer,
        evidenceIndex: ASKEvidenceIndex
    ) async throws -> [ASKWorkWikiDoctorFinding] {
        let pending = try maintainer.pendingPatchPlans()
        var findings: [ASKWorkWikiDoctorFinding] = []

        if !pending.isEmpty {
            findings.append(
                ASKWorkWikiDoctorFinding(
                    kind: "pending_patch",
                    severity: "info",
                    count: pending.count,
                    items: pending.map(\.patchID).sorted()
                )
            )
        }

        let workReportWrites = pending.flatMap { patch in
            patch.projectionWrites
                .filter { $0.document.metadata.subjectKind == ASKWorkWikiProjectionSubjectKind.workReport }
                .map { (patch: patch, write: $0) }
        }

        let missingSourceIDs = workReportWrites
            .filter { $0.write.document.metadata.sourceIDs.isEmpty }
            .map { "\($0.patch.patchID)::\($0.write.slug)" }
            .sorted()
        if !missingSourceIDs.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "pending_work_report_missing_source_ids", severity: "error", count: missingSourceIDs.count, items: missingSourceIDs))
        }

        var staleSourceItems: [String] = []
        var missingSourceItems: [String] = []
        var unindexedSourceItems: [String] = []
        for entry in workReportWrites {
            for sourceID in entry.write.document.metadata.sourceIDs {
                let status: ASKEvidenceDocumentStatus?
                do {
                    status = try await evidenceIndex.freshness(sourceID: SourceID(sourceID))
                } catch {
                    throw ASKWorkWikiError(.freshnessCheckFailed, "failed to check pending work report source freshness", context: ["sourceID": sourceID, "cause": String(describing: error)])
                }
                let item = "\(entry.patch.patchID)::\(entry.write.slug)::\(sourceID)"
                guard let status else {
                    unindexedSourceItems.append(item)
                    continue
                }
                switch status.freshness {
                case .stale:
                    staleSourceItems.append(item)
                case .missing:
                    missingSourceItems.append(item)
                case .ok, .unknown:
                    break
                }
            }
        }
        if !missingSourceItems.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "pending_work_report_source_missing", severity: "error", count: missingSourceItems.count, items: missingSourceItems.sorted()))
        }
        if !staleSourceItems.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "pending_work_report_source_stale", severity: "warning", count: staleSourceItems.count, items: staleSourceItems.sorted()))
        }
        if !unindexedSourceItems.isEmpty {
            findings.append(ASKWorkWikiDoctorFinding(kind: "pending_work_report_source_not_indexed", severity: "warning", count: unindexedSourceItems.count, items: unindexedSourceItems.sorted()))
        }

        return findings
    }

    private static func statusItem(_ status: ASKEvidenceDocumentStatus) -> String {
        let path = status.sourcePath ?? status.sourceID.rawValue
        return "\(status.sourceID.rawValue)::\(path)"
    }

    private static func documentItem(_ metadata: ASKEvidenceMetadata) -> String {
        let path = metadata.sourcePath ?? metadata.sourceID.rawValue
        return "\(metadata.sourceID.rawValue)::\(path)"
    }

    private static func normalizeSeverity(_ severity: String) -> String {
        switch severity.lowercased() {
        case "error", "high": return "error"
        case "warning", "medium": return "warning"
        case "info", "low": return "info"
        default: return severity.lowercased()
        }
    }

    private static func severityRank(_ severity: String) -> Int {
        switch normalizeSeverity(severity) {
        case "error": return 3
        case "warning": return 2
        case "info": return 1
        default: return 0
        }
    }
}
