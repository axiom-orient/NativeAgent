import ASK
import Foundation
import KnowledgeCore
import KnowledgeRuntime

private enum ProbeError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
enum ProductionCorpusConsumer {
    private static let positiveScenarios = [
        "01_ingest_owner_note",
        "02_ingest_architecture_note",
        "03_register_owner_authority",
        "04_refresh_current_snapshot",
        "05_query_file_back",
    ]

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeError.failed(message) }
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try CanonicalJSON.decode(type, from: Data(contentsOf: url))
    }

    private static func scenarioURL(_ root: URL, _ scenario: String, _ filename: String) -> URL {
        root.appendingPathComponent(scenario, isDirectory: true).appendingPathComponent(filename)
    }

    private static func planShape(_ plan: KnowledgePatchPlan) -> String {
        [
            plan.sourceReceipts.count,
            plan.sourceFragments.count,
            plan.authorityRecords.count,
            plan.projectionInvalidations.count,
            plan.projectionWrites.count,
            plan.claims.count,
            plan.evidence.count,
            plan.claimEvidence.count,
            plan.reviewItems.count,
        ].map(String.init).joined(separator: "/")
    }

    private static func requirePlanParity(
        _ actual: KnowledgePatchPlan,
        _ expected: KnowledgePatchPlan,
        scenario: String
    ) throws {
        guard actual == expected else {
            print("CORPUS DETAIL scenario=" + scenario + " actual=" + actual.patchID + "/" + planShape(actual) + " expected=" + expected.patchID + "/" + planShape(expected))
            print("CORPUS DETAIL actualWarnings=" + actual.warnings.joined(separator: ",") + " expectedWarnings=" + expected.warnings.joined(separator: ","))
            print("CORPUS DETAIL actualWrites=" + actual.projectionWrites.map(\.slug).joined(separator: ",") + " expectedWrites=" + expected.projectionWrites.map(\.slug).joined(separator: ","))
            print("CORPUS DETAIL sameSources=\(actual.sourceReceipts == expected.sourceReceipts) sameFragments=\(actual.sourceFragments == expected.sourceFragments) sameAuthorities=\(actual.authorityRecords == expected.authorityRecords) sameInvalidations=\(actual.projectionInvalidations == expected.projectionInvalidations) sameWrites=\(actual.projectionWrites == expected.projectionWrites) sameClaims=\(actual.claims == expected.claims) sameEvidence=\(actual.evidence == expected.evidence) sameVerification=\(actual.verification == expected.verification) sameOperations=\(actual.operations == expected.operations)")
            if let actualDocument = actual.projectionWrites.first?.document, let expectedDocument = expected.projectionWrites.first?.document {
                print("CORPUS DETAIL actualDocHash=\(actualDocument.generatedFromHash) expectedDocHash=\(expectedDocument.generatedFromHash)")
                let actualBody = Array(actualDocument.bodyMD)
                let expectedBody = Array(expectedDocument.bodyMD)
                var firstDifference: Int?
                for index in 0 ..< min(actualBody.count, expectedBody.count) where actualBody[index] != expectedBody[index] {
                    firstDifference = index
                    break
                }
                if firstDifference == nil, actualBody.count != expectedBody.count {
                    firstDifference = min(actualBody.count, expectedBody.count)
                }
                let differenceText = firstDifference.map(String.init) ?? "none"
                print("CORPUS DETAIL actualBodyLength=\(actualBody.count) expectedBodyLength=\(expectedBody.count) firstDifference=\(differenceText)")
                print("CORPUS DETAIL actualBody=\(actualDocument.bodyMD)")
                print("CORPUS DETAIL expectedBody=\(expectedDocument.bodyMD)")
            }
            throw ProbeError.failed(scenario + ": generated plan differs from production corpus")
        }
    }

    private static func copyRawEvidence(
        for request: IngestEvidenceRequest,
        from corpusVault: URL,
        to workspace: URL
    ) throws {
        let source = corpusVault.appendingPathComponent(request.source.rawRelpath)
        try require(FileManager.default.fileExists(atPath: source.path), "missing corpus raw evidence: " + source.path)
        let destination = workspace.appendingPathComponent(request.source.rawRelpath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func applyApproved(
        _ plan: KnowledgePatchPlan,
        receiptURL: URL,
        runtime: ASKRuntime,
        scenario: String
    ) throws {
        let receipt = try load(PatchDecisionReceipt.self, from: receiptURL)
        try require(receipt.patchID == plan.patchID, scenario + ": receipt patch id mismatch")
        let result = try runtime.apply(plan, receipt)
        try require(result.patchID == plan.patchID, scenario + ": apply returned the wrong patch id")
        try require(result.decision == "approved", scenario + ": expected approved apply result")
        print("CORPUS PASS scenario=\(scenario) patch=\(plan.patchID) shape=\(planShape(plan))")
    }

    private static func runPositiveCorpus(
        corpusRoot: URL,
        corpusVault: URL
    ) throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-production-corpus-\(UUID().uuidString)", isDirectory: true)
        let runtime = ASKRuntime(root: workspace)
        _ = try runtime.ensureVault()

        let ownerRequest = try load(
            IngestEvidenceRequest.self,
            from: scenarioURL(corpusRoot, positiveScenarios[0], "ingest_request.json")
        )
        let architectureRequest = try load(
            IngestEvidenceRequest.self,
            from: scenarioURL(corpusRoot, positiveScenarios[1], "ingest_request.json")
        )
        try copyRawEvidence(for: ownerRequest, from: corpusVault, to: workspace)
        try copyRawEvidence(for: architectureRequest, from: corpusVault, to: workspace)

        let ownerExpected = try load(
            KnowledgePatchPlan.self,
            from: scenarioURL(corpusRoot, positiveScenarios[0], "patch_plan.json")
        )
        let ownerPlan = try runtime.planEvidenceIngest(ownerRequest).patch
        try requirePlanParity(ownerPlan, ownerExpected, scenario: positiveScenarios[0])
        try applyApproved(
            ownerPlan,
            receiptURL: scenarioURL(corpusRoot, positiveScenarios[0], "receipt.json"),
            runtime: runtime,
            scenario: positiveScenarios[0]
        )

        let architectureExpected = try load(
            KnowledgePatchPlan.self,
            from: scenarioURL(corpusRoot, positiveScenarios[1], "patch_plan.json")
        )
        let architecturePlan = try runtime.planEvidenceIngest(architectureRequest).patch
        try requirePlanParity(architecturePlan, architectureExpected, scenario: positiveScenarios[1])
        try applyApproved(
            architecturePlan,
            receiptURL: scenarioURL(corpusRoot, positiveScenarios[1], "receipt.json"),
            runtime: runtime,
            scenario: positiveScenarios[1]
        )

        let authorityRequest = try load(
            RegisterAuthorityRequest.self,
            from: scenarioURL(corpusRoot, positiveScenarios[2], "request.json")
        )
        let authorityExpected = try load(
            KnowledgePatchPlan.self,
            from: scenarioURL(corpusRoot, positiveScenarios[2], "patch_plan.json")
        )
        let authorityPlan = try runtime.planAuthorityRegistration(
            authorityRequest,
            existingRecords: []
        ).patch
        try requirePlanParity(authorityPlan, authorityExpected, scenario: positiveScenarios[2])
        try applyApproved(
            authorityPlan,
            receiptURL: scenarioURL(corpusRoot, positiveScenarios[2], "receipt.json"),
            runtime: runtime,
            scenario: positiveScenarios[2]
        )

        let refreshRequest = try load(
            RefreshProjectionRequest.self,
            from: scenarioURL(corpusRoot, positiveScenarios[3], "request.json")
        )
        let refreshExpected = try load(
            KnowledgePatchPlan.self,
            from: scenarioURL(corpusRoot, positiveScenarios[3], "patch_plan.json")
        )
        let refreshPlan = try runtime.planProjectionRefresh(refreshRequest).patch
        try requirePlanParity(refreshPlan, refreshExpected, scenario: positiveScenarios[3])
        try applyApproved(
            refreshPlan,
            receiptURL: scenarioURL(corpusRoot, positiveScenarios[3], "receipt.json"),
            runtime: runtime,
            scenario: positiveScenarios[3]
        )

        let queryExpected = try load(
            KnowledgePatchPlan.self,
            from: scenarioURL(corpusRoot, positiveScenarios[4], "patch_plan.json")
        )
        let question = try String(
            contentsOf: scenarioURL(corpusRoot, positiveScenarios[4], "question.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let fileBackSlug = try requireValue(
            queryExpected.projectionWrites.first?.slug,
            "(positiveScenarios[4]): expected a query projection slug"
        )
        let query = try runtime.query(
            question,
            requestedAt: queryExpected.generatedAt,
            fileBackSlug: fileBackSlug
        )
        let queryPlan = try requireValue(query.fileBackPatch, "(positiveScenarios[4]): query did not produce a file-back patch")
        try requirePlanParity(queryPlan, queryExpected, scenario: positiveScenarios[4])
        try require(!query.answer.isEmpty, "(positiveScenarios[4]): query answer is empty")
        try require(!query.citations.isEmpty, "(positiveScenarios[4]): query returned no citations")
        try applyApproved(
            queryPlan,
            receiptURL: scenarioURL(corpusRoot, positiveScenarios[4], "receipt.json"),
            runtime: runtime,
            scenario: positiveScenarios[4]
        )

        let snapshot = try runtime.snapshot()
        try require(snapshot.approvedPatchIDs.count == positiveScenarios.count, "positive corpus: unexpected approved patch count")
        try require(snapshot.authorityRecordCount == 1, "positive corpus: authority record was not materialized")
        let currentProjection = try runtime.projectionDocument(slug: "current/project/ask")
        let queryProjection = try runtime.projectionDocument(slug: fileBackSlug)
        try require(currentProjection != nil, "positive corpus: current projection is missing")
        try require(queryProjection != nil, "positive corpus: query projection is missing")
        let lint = try runtime.lint()
        if lint.findingCount != 0 {
            print("CORPUS DETAIL lint=" + String(describing: lint.findings))
            throw ProbeError.failed("positive corpus: lint reported \(lint.findingCount) findings")
        }
        print("CORPUS PASS final approved=\(snapshot.approvedPatchIDs.count) authorities=\(snapshot.authorityRecordCount) files=\(snapshot.fileCount)")
    }

    private static func runExistingVaultRead(
        corpusVault: URL
    ) throws {
        let scratchVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-production-vault-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: corpusVault, to: scratchVault)
        let runtime = ASKRuntime(root: scratchVault)
        let rebuild = try runtime.rebuild()
        let snapshot = try runtime.snapshot()
        try require(snapshot.authorityRecordCount > 0, "existing production vault: no authority records")
        try require(snapshot.searchDocCount > 0, "existing production vault: no search documents")
        let search = try runtime.search("truth boundary", limit: 8)
        try require(!search.hits.isEmpty, "existing production vault: truth-boundary search returned no hits")
        let query = try runtime.query(
            "Who owns Agent-Synced Knowledge and what is the truth boundary?",
            requestedAt: "2026-04-06T09:40:00Z"
        )
        try require(!query.answer.isEmpty, "existing production vault: grounded query answer is empty")
        try require(!query.citations.isEmpty, "existing production vault: grounded query has no citations")
        print("CORPUS PASS existingVault rebuilt=\(rebuild.approvedPatchIDs.count) authorities=\(snapshot.authorityRecordCount) searchDocs=\(snapshot.searchDocCount) hits=\(search.hits.count) citations=\(query.citations.count)")
    }

    private static func runNegativeCorpus(
        corpusRoot: URL
    ) throws {
        let negativeRoot = corpusRoot.appendingPathComponent("06_negative_cases", isDirectory: true)
        for (filename, warning) in [
            ("historical_refresh_blocked.json", "historical_rewrite_blocked"),
            ("playbook_requires_approval.json", "playbook_promotion_blocked"),
        ] {
            let plan = try load(KnowledgePatchPlan.self, from: negativeRoot.appendingPathComponent(filename))
            try plan.validate()
            try require(plan.warnings.contains(warning), "negative fixture (filename): expected warning (warning)")
            try require(plan.projectionWrites.isEmpty, "negative fixture (filename): blocked write was not removed")
            try require(plan.verification.requiresHumanApproval, "negative fixture (filename): approval guard is missing")
            print("CORPUS PASS negativeFixture=\(filename) warning=\(warning)")
        }

        let request = try load(
            IngestEvidenceRequest.self,
            from: negativeRoot.appendingPathComponent("missing_raw_ingest_request.json")
        )
        let expected = try load(
            KnowledgePatchPlan.self,
            from: negativeRoot.appendingPathComponent("missing_raw_patch_plan.json")
        )
        let receipt = try load(
            PatchDecisionReceipt.self,
            from: negativeRoot.appendingPathComponent("missing_raw_receipt.json")
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-production-corpus-negative-\(UUID().uuidString)", isDirectory: true)
        let runtime = ASKRuntime(root: workspace)
        _ = try runtime.ensureVault()
        let actual = try runtime.planEvidenceIngest(request).patch
        try requirePlanParity(actual, expected, scenario: "missing_raw")
        do {
            _ = try runtime.apply(actual, receipt)
            throw ProbeError.failed("missing_raw: approved patch unexpectedly applied without raw evidence")
        } catch let error as ProbeError {
            throw error
        } catch {
            print("CORPUS PASS negativeFixture=missing_raw failClosed=true error=\(error)")
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeError.failed(message) }
        return value
    }

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--public-documents-reopen" {
                guard arguments.count == 3 else { throw ProbeError.failed("invalid public corpus reopen arguments") }
                try await PublicDocumentsProbe.reopen(manifestURL: URL(fileURLWithPath: arguments[1]), workspace: URL(fileURLWithPath: arguments[2]))
                return
            }
            if arguments.first == "--public-documents" {
                guard arguments.count == 2 else {
                    throw ProbeError.failed("usage: ProductionCorpusConsumer --public-documents <manifest.json>")
                }
                try await PublicDocumentsProbe.run(manifestURL: URL(fileURLWithPath: arguments[1]))
                return
            }
            guard let corpusPath = arguments.first else {
                throw ProbeError.failed("usage: ProductionCorpusConsumer <production_corpus> [operator_workflow_vault]")
            }
            let corpusRoot = URL(fileURLWithPath: corpusPath, isDirectory: true)
            let corpusVault = URL(
                fileURLWithPath: arguments.dropFirst().first
                    ?? corpusRoot.deletingLastPathComponent().appendingPathComponent("examples/operator_workflow_vault").path,
                isDirectory: true
            )
            try require(FileManager.default.fileExists(atPath: corpusRoot.appendingPathComponent("manifest.json").path), "production corpus manifest is missing")
            try require(FileManager.default.fileExists(atPath: corpusVault.appendingPathComponent(".ask").path), "operator workflow vault is missing")
            try runExistingVaultRead(corpusVault: corpusVault)
            try runPositiveCorpus(corpusRoot: corpusRoot, corpusVault: corpusVault)
            try runNegativeCorpus(corpusRoot: corpusRoot)
            print("PRODUCTION CORPUS VERIFICATION PASS")
        } catch {
            print("PRODUCTION CORPUS VERIFICATION FAIL: \(error)")
            if let diagnostic = error as? ASKDiagnostic {
                print("PUBLIC CORPUS DIAGNOSTIC code=\(diagnostic.code.rawValue) context=\(diagnostic.context)")
            }
            Foundation.exit(1)
        }
    }
}


/// Real public Markdown documents are the input oracle. No generated plans or
/// model output is used as a gold answer. All mutations use an isolated workspace.
enum PublicDocumentsProbe {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let fetchedAt: String
        let documents: [Document]
    }

    private struct Document: Decodable {
        let id: String
        let repository: String
        let commit: String
        let repositoryPath: String
        let sourceURL: String
        let rawURL: String
        let localFile: String
        let sha256: String
        let byteCount: Int
        let language: String
        let searchTerm: String
        let termLine: Int
        let termLineText: String
    }

    private struct ReopenRecord: Codable {
        let documentID: String
        let patchID: String
        let projectionSlug: String
        let reference: Data
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    static func run(manifestURL: URL) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try require(manifest.schemaVersion == 1, "unsupported public corpus manifest version")
        try require(!manifest.documents.isEmpty, "public document corpus is empty")
        try require(Set(manifest.documents.map(\.id)).count == manifest.documents.count, "duplicate public document IDs")
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-public-documents-\(UUID().uuidString)", isDirectory: true)
        // The existing root report workflow consumes work-scoped evidence.
        // Store unchanged public documents as work references instead of adding
        // synthetic frontmatter to the downloaded bytes.
        let sources = workspace.appendingPathComponent("work/references", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var rawLines: [String: [String]] = [:]
        for doc in manifest.documents {
            try require(!doc.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty corpus search term")
            try require(doc.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil, "invalid corpus ID")
            try require(doc.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil, "unpinned corpus commit")
            try require(doc.rawURL.contains("/\(doc.commit)/") && doc.sourceURL.contains("/\(doc.commit)/"), "corpus URLs are not commit pinned")
            let data = try Data(contentsOf: URL(fileURLWithPath: doc.localFile, relativeTo: manifestURL.deletingLastPathComponent()))
            try require(data.count == doc.byteCount && ASKSHA256.hexDigest(data) == doc.sha256, "corpus bytes/hash mismatch: \(doc.id)")
            guard let text = String(data: data, encoding: .utf8) else { throw Failure(description: "corpus is not UTF-8: \(doc.id)") }
            let lines = text.components(separatedBy: "\n")
            try require(doc.termLine > 0 && doc.termLine <= lines.count, "term line outside corpus document")
            try require(lines[doc.termLine - 1] == doc.termLineText && doc.termLineText.localizedCaseInsensitiveContains(doc.searchTerm), "lexical oracle not present in original source: \(doc.id)")
            rawLines[doc.id] = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            try data.write(to: sources.appendingPathComponent(doc.id + ".md"), options: .atomic)
            print("PUBLIC CORPUS SOURCE id=\(doc.id) language=\(doc.language) bytes=\(data.count) commit=\(doc.commit) sha256=\(doc.sha256) url=\(doc.sourceURL)")
        }
        let configuration = ASKConfiguration(workspaceURL: workspace)
        let client = ASKClient(configuration: configuration)
        let indexPlan = try client.plan(.indexWorkspace(ASKIndexWorkspaceCommand(sourceRootURL: sources)))
        _ = try client.dryRun(indexPlan)
        guard case .sourcesIndexed(let indexed) = try await client.apply(indexPlan) else {
            throw Failure(description: "indexWorkspace did not return completed source publication")
        }
        try require(indexed.indexedSourceIDs.count == manifest.documents.count && indexed.skippedCount == 0, "public documents were not all indexed")
        var sourceIDs: [String: String] = [:]
        for sourceID in indexed.indexedSourceIDs {
            guard case .sourceInspect(let inspected) = try await client.query(.sourceInspect(ASKSourceInspectQuery(sourceID: sourceID))) else {
                throw Failure(description: "sourceInspect returned incorrect result")
            }
            guard let doc = manifest.documents.first(where: { $0.sha256 == inspected.checksum }) else {
                throw Failure(description: "indexed document checksum absent from public corpus")
            }
            try require(inspected.contentLength == doc.byteCount, "indexed source byte length mismatch")
            sourceIDs[doc.id] = sourceID
        }
        try require(sourceIDs.count == manifest.documents.count, "source identities are not one-to-one with corpus documents")
        print("PUBLIC CORPUS PASS indexed=\(sourceIDs.count) skipped=\(indexed.skippedCount)")

        var reopenRecords: [ReopenRecord] = []
        for (index, doc) in manifest.documents.enumerated() {
            guard let sourceID = sourceIDs[doc.id], let lines = rawLines[doc.id] else {
                throw Failure(description: "missing indexed corpus document")
            }
            guard case .evidenceSearch(let search) = try await client.query(.searchEvidence(ASKEvidenceSearchQuery(text: doc.searchTerm, limit: 256))) else {
                throw Failure(description: "evidence search returned incorrect result")
            }
            try require(search.items.contains { $0.sourceID == sourceID }, "search did not find expected source: \(doc.id)")
            guard case .groundedEvidence(let pack) = try await client.query(.groundedEvidence(ASKGroundedEvidenceQuery(text: doc.searchTerm, limit: 256, maxBytes: 1_048_576))) else {
                throw Failure(description: "grounded evidence returned incorrect result")
            }
            var checkedReferenceCount = 0
            var chosenReferenceData: Data?
            for hit in pack.evidence where hit.reference.sourceID.rawValue == sourceID {
                try require(hit.reference.sourceVersionChecksum == doc.sha256, "citation source version differs from downloaded bytes")
                guard case .resolvedEvidence(.available(let content)) = try await client.query(.resolveEvidence(ASKResolveEvidenceQuery(reference: hit.reference))) else {
                    throw Failure(description: "exact citation did not resolve: \(doc.id)")
                }
                try require(content.sourceFreshness.rawValue == "ok", "downloaded source is not fresh")
                try require(!content.excerpts.isEmpty, "empty exact citation")
                for excerpt in content.excerpts {
                    try require(excerpt.index > 0 && excerpt.index <= lines.count, "citation line outside source")
                    try require(excerpt.content == lines[excerpt.index - 1], "citation differs from independent original raw line")
                }
                if content.excerpts.contains(where: { $0.content.localizedCaseInsensitiveContains(doc.searchTerm) }) {
                    checkedReferenceCount += 1
                    chosenReferenceData = try JSONEncoder().encode(hit.reference)
                }
            }
            try require(checkedReferenceCount > 0, "no original-byte verified citation includes expected term: \(doc.id)")
            let slug = "queries/public-corpus/" + doc.id
            let requestedAt = String(format: "2026-09-12T02:%02d:00Z", index * 2)
            let decidedAt = String(format: "2026-09-12T02:%02d:00Z", index * 2 + 1)
            guard case .staged(.report(let staged)) = try await client.apply(try client.plan(.stageReport(ASKStageReportCommand(
                title: "Public documentation review: " + doc.id, queryText: doc.searchTerm,
                requestedAt: requestedAt, slug: slug, maxEvidenceBytes: 1_048_576
            )))) else { throw Failure(description: "report proposal was not staged") }
            guard case .pendingPatch(let pending) = try await client.query(.pendingPatch(ASKPendingPatchQuery(patchID: staged.patchID))) else {
                throw Failure(description: "pending report could not be inspected")
            }
            try require(pending.isPending && pending.status == "pending", "stage incorrectly committed the report")
            try require(pending.plan.projectionWrites.contains { $0.document.metadata.sourceVersionChecksums[sourceID] == doc.sha256 }, "pending report lacks the reviewed exact source version")
            guard case .pendingWork(let pendingWork) = try await client.query(.pendingWork(ASKPendingWorkQuery())) else { throw Failure(description: "pending work observation failed") }
            try require(pendingWork.patches.contains { $0.patchID == staged.patchID }, "staged report is not observable pending work")
            guard case .decided(let decision) = try await client.apply(try client.plan(.decidePatch(ASKDecidePatchCommand(
                patchID: staged.patchID, decision: .approved, decidedBy: "public-corpus-verifier",
                decidedAt: decidedAt, reason: "Explicit local acceptance after byte-exact citation and pending proposal inspection"
            )))) else { throw Failure(description: "approved report requires repair or failed to commit") }
            try require(decision.decision == .approved, "report approval returned another decision")
            guard case .knowledgeSearch(let knowledge) = try await client.query(.searchKnowledge(ASKKnowledgeSearchQuery(text: doc.searchTerm, limit: 256))) else { throw Failure(description: "knowledge query failed") }
            try require(knowledge.items.contains { $0.projectionSlug == staged.projectionSlug }, "knowledge search lacks approved report")
            guard case .projection(let projection) = try await client.query(.projection(ASKProjectionQuery(slug: staged.projectionSlug))) else { throw Failure(description: "approved projection missing") }
            try require(projection.body.localizedCaseInsensitiveContains(doc.searchTerm) && projection.body.contains(sourceID), "approved report does not preserve source-backed body")
            let reopened = ASKClient(configuration: configuration)
            guard case .pendingPatch(let decided) = try await reopened.query(.pendingPatch(ASKPendingPatchQuery(patchID: staged.patchID))) else { throw Failure(description: "reopen decision observation failed") }
            try require(!decided.isPending && decided.status == "approved", "reopened decision not approved")
            guard case .projection(let reopenedProjection) = try await reopened.query(.projection(ASKProjectionQuery(slug: staged.projectionSlug))) else { throw Failure(description: "reopened projection missing") }
            try require(reopenedProjection == projection, "reopened projection differs")
            // Infer the exact reference type from the public result; persist and
            // decode it to prove the caller-visible immutable reference survives.
            guard let originalReference = pack.evidence.first(where: { $0.reference.sourceID.rawValue == sourceID })?.reference else {
                throw Failure(description: "citation reference absent")
            }
            guard let serialized = chosenReferenceData else { throw Failure(description: "verified original-byte citation absent") }
            let reference = try JSONDecoder().decode(type(of: originalReference), from: serialized)
            guard case .resolvedEvidence(.available(let reopenedContent)) = try await reopened.query(.resolveEvidence(ASKResolveEvidenceQuery(reference: reference))) else { throw Failure(description: "reopened exact citation missing") }
            try require(reopenedContent.reference == reference, "reopened citation identity changed")
            guard case .storageHealth(let health) = try await reopened.query(.storageHealth(ASKStorageHealthQuery())) else { throw Failure(description: "health result missing") }
            try require(health.isHealthy, "reopened storage unhealthy: \(health.components)")
            reopenRecords.append(ReopenRecord(documentID: doc.id, patchID: staged.patchID, projectionSlug: staged.projectionSlug, reference: serialized))
            print("PUBLIC CORPUS PASS id=\(doc.id) searchHits=\(search.items.count) exactCitations=\(checkedReferenceCount) pendingReviewed=true approved=true projection=\(staged.projectionSlug) reopened=true health=true")
        }
        guard case .pendingWork(let finalPending) = try await ASKClient(configuration: configuration).query(.pendingWork(ASKPendingWorkQuery())) else { throw Failure(description: "final pending observation failed") }
        try require(finalPending.patches.isEmpty && finalPending.presentationRepairs.isEmpty, "unfinished pending work or repairs after public corpus")
        try JSONEncoder().encode(reopenRecords).write(to: workspace.appendingPathComponent("public-corpus-observations.json"), options: .atomic)
        let child = Process()
        guard let executableURL = Bundle.main.executableURL else { throw Failure(description: "cannot locate public corpus verifier executable") }
        child.executableURL = executableURL
        child.arguments = ["--public-documents-reopen", manifestURL.path, workspace.path]
        try child.run()
        child.waitUntilExit()
        try require(child.terminationReason == .exit && child.terminationStatus == 0, "independent process could not reopen persisted public document workspace")
        print("PUBLIC DOCUMENTS VERIFICATION PASS documents=\(manifest.documents.count) workspace=\(workspace.path) manifest=\(manifestURL.path)")
    }

    /// Separate-process read qualification avoids reusing the in-process source
    /// handle pool and checks caller-persisted citations against the raw corpus.
    static func reopen(manifestURL: URL, workspace: URL) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let records = try JSONDecoder().decode([ReopenRecord].self, from: Data(contentsOf: workspace.appendingPathComponent("public-corpus-observations.json")))
        try require(records.count == manifest.documents.count, "reopen observation count mismatch")
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        for record in records {
            guard let doc = manifest.documents.first(where: { $0.id == record.documentID }) else { throw Failure(description: "unknown reopened document") }
            let raw = try Data(contentsOf: workspace.appendingPathComponent("work/references/" + doc.id + ".md"))
            try require(ASKSHA256.hexDigest(raw) == doc.sha256, "reopened source bytes differ from commit-pinned corpus")
            guard let text = String(data: raw, encoding: .utf8) else { throw Failure(description: "reopened source is not UTF-8") }
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            guard case .groundedEvidence(let pack) = try await client.query(.groundedEvidence(ASKGroundedEvidenceQuery(text: doc.searchTerm, limit: 256, maxBytes: 1_048_576))),
                  let sample = pack.evidence.first?.reference else { throw Failure(description: "reopened source search empty") }
            let reference = try JSONDecoder().decode(type(of: sample), from: record.reference)
            guard case .resolvedEvidence(.available(let content)) = try await client.query(.resolveEvidence(ASKResolveEvidenceQuery(reference: reference))) else { throw Failure(description: "persisted citation cannot resolve in another process") }
            try require(reference.sourceVersionChecksum == doc.sha256 && content.reference == reference && content.sourceFreshness.rawValue == "ok", "reopened exact citation identity/freshness mismatch")
            for excerpt in content.excerpts {
                try require(excerpt.index > 0 && excerpt.index <= lines.count && excerpt.content == lines[excerpt.index - 1], "reopened citation differs from original source line")
            }
            try require(content.excerpts.contains { $0.content.localizedCaseInsensitiveContains(doc.searchTerm) }, "reopened citation lost original lexical evidence")
            guard case .pendingPatch(let decision) = try await client.query(.pendingPatch(ASKPendingPatchQuery(patchID: record.patchID))) else { throw Failure(description: "reopened decision missing") }
            try require(!decision.isPending && decision.status == "approved", "persisted decision is not approved")
            guard case .knowledgeSearch(let search) = try await client.query(.searchKnowledge(ASKKnowledgeSearchQuery(text: doc.searchTerm, limit: 256))) else { throw Failure(description: "reopened knowledge search failed") }
            try require(search.items.contains { $0.projectionSlug == record.projectionSlug }, "reopened knowledge search lost report")
            guard case .projection(let projection) = try await client.query(.projection(ASKProjectionQuery(slug: record.projectionSlug))) else { throw Failure(description: "reopened report missing") }
            try require(projection.body.contains(reference.sourceID.rawValue) && projection.body.localizedCaseInsensitiveContains(doc.searchTerm), "reopened report lost source-grounded content")
            print("PUBLIC CORPUS REOPEN PASS id=\(doc.id) separateProcess=true originalBytes=true persistedCitation=true decision=approved")
        }
        guard case .storageHealth(let health) = try await client.query(.storageHealth(ASKStorageHealthQuery())) else { throw Failure(description: "reopened process health missing") }
        try require(health.isHealthy, "separate-process storage health is not healthy")
        print("PUBLIC CORPUS REOPEN PASS documents=\(records.count) health=true")
    }

}
