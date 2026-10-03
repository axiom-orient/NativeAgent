import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

private func representationTempDir(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test
func persistedRepresentationRejectsUnsupportedVersionWithoutRewritingIt() throws {
    let root = try representationTempDir("ask-unsupported-representation")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()
    let record = RepresentationRecord(version: "1", sourceID: "source", kind: .ocrText,
        sourceContentHash: "hash", generatedAt: "2026-09-13T00:00:00Z",
        generator: "test", bodyMD: "Preserved content")
    let url = root.appendingPathComponent("records/representations/source/ocr_text.json")
    try CanonicalJSON.dump(record, to: url)
    let preserved = try Data(contentsOf: url)
    #expect(throws: ASKError.self) { try runtime.listRepresentations(sourceID: "source") }
    #expect(throws: ASKError.self) { try Vault(root: root).loadRepresentation(sourceID: "source", kind: .ocrText) }
    #expect(try Data(contentsOf: url) == preserved)
}

@Test
func persistedGenerationMarkerRejectsUnsupportedSchema() throws {
    let root = try representationTempDir("ask-unsupported-generation")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()
    let vault = Vault(root: root)
    _ = try runtime.rebuild()
    var marker = try #require(try vault.readGenerationMarker())
    marker.schemaVersion = 1
    try CanonicalJSON.dump(marker, to: vault.generationMarkerURL())
    let preserved = try Data(contentsOf: vault.generationMarkerURL())
    #expect(throws: ASKError.self) { try vault.readGenerationMarker() }
    #expect(try Data(contentsOf: vault.generationMarkerURL()) == preserved)
}

@Test
func importCollectedAcceptsGenericCollectorFamily() throws {
    let vaultRoot = try representationTempDir("ask-generic-collector-vault")
    let stagingRoot = try representationTempDir("ask-generic-collector-stage")
    defer {
        try? FileManager.default.removeItem(at: vaultRoot)
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    let runtime = ASKRuntime(root: vaultRoot)
    _ = try runtime.ensureVault()

    let sourceID = "src_local_text"
    let rawBytes = Data("Local source import from macOS.".utf8)
    let rawRelpath = "raw/evidence/2026-04-11/\(sourceID).txt"
    let noteRelpath = ".ask/collector/local-file/\(sourceID)/curated_note.md"
    let captureDirectory = stagingRoot.appendingPathComponent(".ask/collector/local-file/\(sourceID)", isDirectory: true)
    let rawPath = stagingRoot.appendingPathComponent(rawRelpath)

    try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rawPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rawBytes.write(to: rawPath, options: .atomic)

    let manifest = CollectedCaptureManifest(
        sourceID: sourceID,
        connector: "local-file-import",
        transport: "local_text_file",
        originalURL: "file:///tmp/local.txt",
        finalURL: "file:///tmp/local.txt",
        title: "Local Text",
        observedAt: "2026-04-11T10:00:00Z",
        capturedAt: "2026-04-11T10:00:00Z",
        rawRelpath: rawRelpath,
        noteRelpath: noteRelpath,
        contentHash: ASKSHA256.prefixedDigest(rawBytes),
        mimeType: "text/plain",
        language: "en",
        tags: ["local"],
        metadata: [
            "import_family": "local-file",
            "source_filename": "local.txt"
        ],
        fragments: [
            CollectedCaptureFragment(
                fragmentID: "frag_local_0",
                ordinal: 0,
                text: "Local source import from macOS.",
                locator: ["block": "0"],
                fingerprint: stableHash(["Local source import from macOS."])
            )
        ]
    )
    let collected = CollectedSource(
        sourceID: sourceID,
        connector: "local-file-import",
        sourceKind: .file,
        title: "Local Text",
        observedAt: "2026-04-11T10:00:00Z",
        capturedAt: "2026-04-11T10:00:00Z",
        rawRelpath: rawRelpath,
        contentHash: ASKSHA256.prefixedDigest(rawBytes),
        mimeType: "text/plain",
        language: "en",
        tags: ["local"],
        metadata: [
            "import_family": "local-file",
            "source_filename": "local.txt"
        ],
        fragments: [
            CollectedFragment(
                fragmentID: "frag_local_0",
                ordinal: 0,
                locator: ["block": "0"],
                text: "Local source import from macOS.",
                fingerprint: stableHash(["Local source import from macOS."])
            )
        ]
    )

    let manifestPath = captureDirectory.appendingPathComponent("capture_manifest.json")
    let collectedPath = captureDirectory.appendingPathComponent("collected_source.json")
    let notePath = captureDirectory.appendingPathComponent("curated_note.md")
    try (CanonicalJSON.data(for: manifest) + Data([0x0a])).write(to: manifestPath, options: .atomic)
    try (CanonicalJSON.data(for: collected) + Data([0x0a])).write(to: collectedPath, options: .atomic)
    try "# Local Text\n\nLocal source import from macOS.".write(to: notePath, atomically: true, encoding: .utf8)

    let imported = try runtime.importCollected(manifestPath)
    let importedCollected = try CanonicalJSON.decode(CollectedSource.self, from: Data(contentsOf: URL(fileURLWithPath: imported.collectedPath)))

    #expect(imported.rawRelpath == rawRelpath)
    #expect(importedCollected.metadata["import_family"] == "local-file")
    #expect(FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(noteRelpath).path))
    #expect(FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(rawRelpath).path))
}

@Test
func representationRoundTripPersistsAndLoads() throws {
    let root = try representationTempDir("ask-representation-roundtrip")
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    let record = RepresentationRecord(
        sourceID: "src_pdf_001",
        kind: .ocrText,
        sourceContentHash: "sha256:demo",
        generatedAt: "2026-04-11T11:00:00Z",
        generator: "ocr.demo",
        bodyMD: "OCR text for the imported PDF.",
        metadata: ["page_count": "1"]
    )

    try runtime.upsertRepresentation(record)

    let loaded = try runtime.representation(sourceID: "src_pdf_001", kind: .ocrText)
    let all = try runtime.listRepresentations(sourceID: "src_pdf_001")

    #expect(loaded == record)
    #expect(all == [record])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("records/representations/src_pdf_001/ocr_text.json").path))
}

@Test
func representationAPIsRejectPathUnsafeSourceID() throws {
    let root = try representationTempDir("ask-representation-hardening")
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    #expect(throws: ASKError.self) {
        try runtime.upsertRepresentation(
            RepresentationRecord(
                sourceID: "../escape",
                kind: .ocrText,
                sourceContentHash: "sha256:demo",
                generatedAt: "2026-04-11T11:00:00Z",
                generator: "ocr.demo",
                bodyMD: "Unsafe representation."
            )
        )
    }
    #expect(throws: ASKError.self) {
        _ = try runtime.representation(sourceID: "../escape", kind: .ocrText)
    }
    #expect(throws: ASKError.self) {
        _ = try runtime.listRepresentations(sourceID: "../escape")
    }
    #expect(throws: ASKError.self) {
        _ = try runtime.lintRepresentations(
            RepresentationTrailRequest(
                sourceID: "../escape",
                sourceContentHash: "sha256:demo",
                requiredKinds: [.ocrText]
            )
        )
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
}

@Test
func representationLintReportsMissingAndStaleKinds() throws {
    let root = try representationTempDir("ask-representation-lint")
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    try runtime.upsertRepresentation(
        RepresentationRecord(
            sourceID: "src_asset_001",
            kind: .ocrText,
            sourceContentHash: "sha256:old",
            generatedAt: "2026-04-11T12:00:00Z",
            generator: "ocr.demo",
            bodyMD: "Old OCR text."
        )
    )

    let report = try runtime.lintRepresentations(
        RepresentationTrailRequest(
            sourceID: "src_asset_001",
            sourceContentHash: "sha256:new",
            requiredKinds: [.ocrText, .metadataProfile]
        )
    )

    #expect(report.availableKinds == [.ocrText])
    #expect(report.findings.count == 2)
    #expect(report.findings.contains { $0.kind == "stale_representation" && $0.item == RepresentationKind.ocrText.rawValue })
    #expect(report.findings.contains { $0.kind == "missing_representation" && $0.item == RepresentationKind.metadataProfile.rawValue })
}

@Test
func pendingPatchPlanCanBeLoadedAndDecidedAfterStaging() throws {
    let root = try representationTempDir("ask-pending-patch")
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    let rawText = Data("Pending patch should be reviewable later.".utf8)
    let rawRelpath = "raw/evidence/2026-04-11/src_pending.txt"
    let rawURL = root.appendingPathComponent(rawRelpath)
    try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rawText.write(to: rawURL)

    let collected = CollectedSource(
        sourceID: "src_pending",
        connector: "local-file-import",
        sourceKind: .file,
        title: "Pending Source",
        observedAt: "2026-04-11T17:00:00Z",
        capturedAt: "2026-04-11T17:00:00Z",
        rawRelpath: rawRelpath,
        contentHash: ASKSHA256.prefixedDigest(rawText),
        mimeType: "text/plain",
        language: "en",
        tags: ["pending"],
        metadata: [:],
        fragments: [
            CollectedFragment(
                fragmentID: "frag_pending_0",
                ordinal: 0,
                locator: [:],
                text: "Pending patch should be reviewable later.",
                fingerprint: stableHash(["Pending patch should be reviewable later."])
            )
        ]
    )

    let request = try toIngestEvidenceRequest(collected, domain: "notes/pending", requestedAt: "2026-04-11T17:01:00Z")
    let outcome = try runtime.planEvidenceIngest(request)
    try runtime.stage(outcome.patch)

    let pending = try runtime.pendingPatchPlans()
    let loaded = try runtime.patchPlan(patchID: outcome.patch.patchID)

    #expect(pending.map(\.patchID).contains(outcome.patch.patchID))
    #expect(loaded?.patchID == outcome.patch.patchID)

    let stagedPlanURL = root
        .appendingPathComponent(".ask/journal/patches", isDirectory: true)
        .appendingPathComponent(outcome.patch.patchID, isDirectory: true)
        .appendingPathComponent("patch.json", isDirectory: false)
    let stagedPlanData = try Data(contentsOf: stagedPlanURL)
    try FileManager.default.removeItem(at: stagedPlanURL)
    var missingPlanWasRejected = false
    do {
        _ = try runtime.pendingPatchPlans()
    } catch {
        missingPlanWasRejected = true
    }
    #expect(missingPlanWasRejected)
    try stagedPlanData.write(to: stagedPlanURL, options: .atomic)

    let apply = try runtime.decidePendingPatch(
        patchID: outcome.patch.patchID,
        decision: .approved,
        decidedBy: "reviewer",
        decidedAt: "2026-04-11T17:02:00Z",
        reason: "approve pending import"
    )
    let snapshot = try runtime.snapshot()

    #expect(apply.patchID == outcome.patch.patchID)
    #expect(snapshot.pendingPatchIDs.contains(outcome.patch.patchID) == false)
    #expect(snapshot.approvedPatchIDs.contains(outcome.patch.patchID))
}


@Test
func pendingChoicePatchCanBeAppliedBySelectingAnOption() throws {
    let root = try representationTempDir("ask-pending-choice-patch")
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    let existing = AuthorityRecord(
        version: authorityRecordVersion,
        recordID: "authority_existing",
        recordType: "current_state",
        subjectKind: "project",
        subjectID: "kapasi",
        factScopeKey: "current_battery_policy",
        approvalState: .approved,
        valueFields: ["threshold": "80"],
        effectiveFrom: "2026-04-01T00:00:00Z",
        effectiveTo: nil,
        approvedBy: "human",
        supersedesID: nil
    )
    let request = RegisterAuthorityRequest(
        version: registerAuthorityRequestVersion,
        record: AuthorityRecord(
            version: authorityRecordVersion,
            recordID: "authority_candidate",
            recordType: "current_state",
            subjectKind: "project",
            subjectID: "kapasi",
            factScopeKey: "current_battery_policy",
            approvalState: .approved,
            valueFields: ["threshold": "85"],
            effectiveFrom: "2026-04-08T09:00:00Z",
            effectiveTo: nil,
            approvedBy: "human",
            supersedesID: nil
        ),
        requestedAt: "2026-04-08T09:00:10Z"
    )
    let plan = try runtime.planAuthorityRegistration(request, existingRecords: [existing]).patch
    try runtime.stage(plan)

    let apply = try runtime.choosePendingPatch(
        patchID: plan.patchID,
        choice: "A",
        decidedBy: "reviewer",
        decidedAt: "2026-04-11T18:00:00Z",
        reason: "select A in pending authority choice"
    )
    let snapshot = try runtime.snapshot()
    let queue = try runtime.reviewQueue()

    #expect(apply.patchID == plan.patchID)
    #expect(snapshot.pendingPatchIDs.contains(plan.patchID) == false)
    #expect(snapshot.approvedPatchIDs.contains(plan.patchID))
    #expect(queue.items.isEmpty)
}
