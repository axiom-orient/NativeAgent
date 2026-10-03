import Foundation
import KnowledgeCore

private let mirrorPragmas = """
PRAGMA foreign_keys = OFF;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
"""

private let mirrorSchema = """
DROP TABLE IF EXISTS source_receipts;
DROP TABLE IF EXISTS source_fragments;
DROP TABLE IF EXISTS authority_records;
DROP TABLE IF EXISTS claims;
DROP TABLE IF EXISTS evidence;
DROP TABLE IF EXISTS claim_evidence;
DROP TABLE IF EXISTS review_items;
DROP TABLE IF EXISTS projection_docs;
DROP TABLE IF EXISTS page_links;
DROP TABLE IF EXISTS projection_invalidations;
DROP TABLE IF EXISTS patch_plans;
DROP TABLE IF EXISTS operation_logs;
DROP TABLE IF EXISTS search_docs_fts;
DROP TABLE IF EXISTS search_docs;

CREATE TABLE source_receipts (
    source_id TEXT PRIMARY KEY,
    version TEXT NOT NULL,
    connector TEXT NOT NULL,
    source_kind TEXT NOT NULL,
    title TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    captured_at TEXT,
    canonical_uri TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    raw_relpath TEXT NOT NULL,
    mime_type TEXT,
    language TEXT,
    tags_json TEXT NOT NULL,
    metadata_json TEXT NOT NULL
);

CREATE TABLE source_fragments (
    fragment_id TEXT PRIMARY KEY,
    version TEXT NOT NULL,
    source_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    locator_json TEXT NOT NULL,
    text TEXT NOT NULL,
    fingerprint TEXT,
    metadata_json TEXT NOT NULL
);

CREATE TABLE authority_records (
    record_id TEXT PRIMARY KEY,
    version TEXT NOT NULL,
    record_type TEXT NOT NULL,
    subject_kind TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    fact_scope_key TEXT NOT NULL,
    approval_state TEXT NOT NULL,
    value_fields_json TEXT NOT NULL,
    effective_from TEXT NOT NULL,
    effective_to TEXT,
    approved_by TEXT,
    supersedes_id TEXT
);

CREATE TABLE claims (
    claim_id TEXT PRIMARY KEY,
    claim_kind TEXT NOT NULL,
    claim_mode TEXT NOT NULL,
    status TEXT NOT NULL,
    subject_kind TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    text TEXT NOT NULL,
    authority_record_id TEXT,
    source_fragment_ids_json TEXT NOT NULL,
    confidence TEXT NOT NULL
);

CREATE TABLE evidence (
    evidence_id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    fragment_id TEXT NOT NULL,
    excerpt TEXT NOT NULL
);

CREATE TABLE claim_evidence (
    claim_id TEXT NOT NULL,
    evidence_id TEXT NOT NULL,
    support_kind TEXT NOT NULL,
    PRIMARY KEY (claim_id, evidence_id)
);

CREATE TABLE review_items (
    review_id TEXT PRIMARY KEY,
    review_kind TEXT NOT NULL,
    status TEXT NOT NULL,
    severity TEXT NOT NULL,
    subject_kind TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    created_at TEXT NOT NULL,
    details_json TEXT NOT NULL
);

CREATE TABLE projection_docs (
    slug TEXT NOT NULL,
    generated_from_hash TEXT NOT NULL,
    version TEXT NOT NULL,
    state TEXT NOT NULL,
    title TEXT NOT NULL,
    subject_kind TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    projection_kind TEXT NOT NULL,
    projection_space TEXT NOT NULL,
    body_md TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    PRIMARY KEY (slug, generated_from_hash)
);

CREATE TABLE page_links (
    from_slug TEXT NOT NULL,
    to_slug TEXT NOT NULL,
    link_kind TEXT NOT NULL,
    anchor_text TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (from_slug, to_slug, link_kind)
);

CREATE TABLE projection_invalidations (
    invalidation_id TEXT PRIMARY KEY,
    slug TEXT NOT NULL,
    reason TEXT NOT NULL,
    triggered_by_patch_id TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE patch_plans (
    patch_id TEXT PRIMARY KEY,
    version TEXT NOT NULL,
    patch_kind TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    status TEXT NOT NULL,
    pending_review_count INTEGER NOT NULL,
    risk_level TEXT NOT NULL,
    disposition TEXT NOT NULL,
    requires_human_approval INTEGER NOT NULL,
    reasons_json TEXT NOT NULL
);

CREATE TABLE operation_logs (
    log_id TEXT PRIMARY KEY,
    occurred_at TEXT NOT NULL,
    op_kind TEXT NOT NULL,
    summary TEXT NOT NULL
);

CREATE TABLE search_docs (
    doc_id TEXT PRIMARY KEY,
    doc_kind TEXT NOT NULL,
    subject_kind TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    projection_slug TEXT,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    metadata_text TEXT NOT NULL
);

CREATE VIRTUAL TABLE search_docs_fts USING fts5(
    doc_id UNINDEXED,
    title,
    body,
    metadata_text,
    content='search_docs',
    content_rowid='rowid',
    tokenize='unicode61'
);
"""

private func jsonString<T: Encodable>(_ value: T) throws -> String {
    try CanonicalJSON.string(for: value)
}

package func rebuildMirror(at path: URL, store: KnowledgeStore) throws {
    let db = try SQLiteDatabase(path: path)
    try db.exec(mirrorPragmas)
    try db.transaction {
        try db.exec(mirrorSchema)

        let insertSource = try db.prepare("INSERT INTO source_receipts VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { insertSource.finalize() }
        for source in store.sources.values.sorted(by: { $0.sourceID < $1.sourceID }) {
            try insertSource.bind(source.sourceID, at: 1)
            try insertSource.bind(source.version, at: 2)
            try insertSource.bind(source.connector, at: 3)
            try insertSource.bind(source.sourceKind.rawValue, at: 4)
            try insertSource.bind(source.title, at: 5)
            try insertSource.bind(source.observedAt, at: 6)
            try insertSource.bind(source.capturedAt, at: 7)
            try insertSource.bind(source.canonicalURI, at: 8)
            try insertSource.bind(source.contentHash, at: 9)
            try insertSource.bind(source.rawRelpath, at: 10)
            try insertSource.bind(source.mimeType, at: 11)
            try insertSource.bind(source.language, at: 12)
            try insertSource.bind(try jsonString(source.tags), at: 13)
            try insertSource.bind(try jsonString(source.metadata), at: 14)
            _ = try insertSource.step()
            try insertSource.reset()
        }

        let insertFragment = try db.prepare("INSERT INTO source_fragments VALUES (?,?,?,?,?,?,?,?)")
        defer { insertFragment.finalize() }
        for fragment in store.sourceFragments.values.sorted(by: { $0.fragmentID < $1.fragmentID }) {
            try insertFragment.bind(fragment.fragmentID, at: 1)
            try insertFragment.bind(fragment.version, at: 2)
            try insertFragment.bind(fragment.sourceID, at: 3)
            try insertFragment.bind(fragment.ordinal, at: 4)
            try insertFragment.bind(try jsonString(fragment.locator), at: 5)
            try insertFragment.bind(fragment.text, at: 6)
            try insertFragment.bind(fragment.fingerprint, at: 7)
            try insertFragment.bind(try jsonString(fragment.metadata), at: 8)
            _ = try insertFragment.step()
            try insertFragment.reset()
        }

        let insertAuthority = try db.prepare("INSERT INTO authority_records VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { insertAuthority.finalize() }
        for record in store.authorityRecords.values.sorted(by: { $0.recordID < $1.recordID }) {
            try insertAuthority.bind(record.recordID, at: 1)
            try insertAuthority.bind(record.version, at: 2)
            try insertAuthority.bind(record.recordType, at: 3)
            try insertAuthority.bind(record.subjectKind, at: 4)
            try insertAuthority.bind(record.subjectID, at: 5)
            try insertAuthority.bind(record.factScopeKey, at: 6)
            try insertAuthority.bind(record.approvalState.rawValue, at: 7)
            try insertAuthority.bind(try jsonString(record.valueFields), at: 8)
            try insertAuthority.bind(record.effectiveFrom, at: 9)
            try insertAuthority.bind(record.effectiveTo, at: 10)
            try insertAuthority.bind(record.approvedBy, at: 11)
            try insertAuthority.bind(record.supersedesID, at: 12)
            _ = try insertAuthority.step()
            try insertAuthority.reset()
        }

        let insertClaim = try db.prepare("INSERT INTO claims VALUES (?,?,?,?,?,?,?,?,?,?)")
        defer { insertClaim.finalize() }
        for claim in store.claims.values.sorted(by: { $0.claimID < $1.claimID }) {
            try insertClaim.bind(claim.claimID, at: 1)
            try insertClaim.bind(claim.claimKind.rawValue, at: 2)
            try insertClaim.bind(claim.claimMode.rawValue, at: 3)
            try insertClaim.bind(claim.status.rawValue, at: 4)
            try insertClaim.bind(claim.subjectKind, at: 5)
            try insertClaim.bind(claim.subjectID, at: 6)
            try insertClaim.bind(claim.text, at: 7)
            try insertClaim.bind(claim.authorityRecordID, at: 8)
            try insertClaim.bind(try jsonString(claim.sourceFragmentIDs), at: 9)
            try insertClaim.bind(claim.confidence.rawValue, at: 10)
            _ = try insertClaim.step()
            try insertClaim.reset()
        }

        let insertEvidence = try db.prepare("INSERT INTO evidence VALUES (?,?,?,?)")
        defer { insertEvidence.finalize() }
        for evidence in store.evidence.values.sorted(by: { $0.evidenceID < $1.evidenceID }) {
            try insertEvidence.bind(evidence.evidenceID, at: 1)
            try insertEvidence.bind(evidence.sourceID, at: 2)
            try insertEvidence.bind(evidence.fragmentID, at: 3)
            try insertEvidence.bind(evidence.excerpt, at: 4)
            _ = try insertEvidence.step()
            try insertEvidence.reset()
        }

        let insertClaimEvidence = try db.prepare("INSERT INTO claim_evidence VALUES (?,?,?)")
        defer { insertClaimEvidence.finalize() }
        for edge in store.claimEvidence {
            try insertClaimEvidence.bind(edge.claimID, at: 1)
            try insertClaimEvidence.bind(edge.evidenceID, at: 2)
            try insertClaimEvidence.bind(edge.supportKind.rawValue, at: 3)
            _ = try insertClaimEvidence.step()
            try insertClaimEvidence.reset()
        }

        let insertReview = try db.prepare("INSERT INTO review_items VALUES (?,?,?,?,?,?,?,?,?)")
        defer { insertReview.finalize() }
        for review in store.reviewItems.values.sorted(by: { $0.reviewID < $1.reviewID }) {
            try insertReview.bind(review.reviewID, at: 1)
            try insertReview.bind(review.reviewKind.rawValue, at: 2)
            try insertReview.bind(review.status.rawValue, at: 3)
            try insertReview.bind(review.severity.rawValue, at: 4)
            try insertReview.bind(review.subjectKind, at: 5)
            try insertReview.bind(review.subjectID, at: 6)
            try insertReview.bind(review.summary, at: 7)
            try insertReview.bind(review.createdAt, at: 8)
            try insertReview.bind(try jsonString(review.details), at: 9)
            _ = try insertReview.step()
            try insertReview.reset()
        }

        let visibleWrites = store.visibleProjectionWrites()

        let insertProjection = try db.prepare("INSERT INTO projection_docs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { insertProjection.finalize() }
        for write in visibleWrites {
            try insertProjection.bind(write.slug, at: 1)
            try insertProjection.bind(write.document.generatedFromHash, at: 2)
            try insertProjection.bind(write.document.version, at: 3)
            try insertProjection.bind(write.state.rawValue, at: 4)
            try insertProjection.bind(write.document.title, at: 5)
            try insertProjection.bind(write.document.metadata.subjectKind, at: 6)
            try insertProjection.bind(write.document.metadata.subjectID, at: 7)
            try insertProjection.bind(write.document.metadata.projectionKind.rawValue, at: 8)
            try insertProjection.bind(write.document.metadata.projectionSpace.rawValue, at: 9)
            try insertProjection.bind(write.document.bodyMD, at: 10)
            try insertProjection.bind(try jsonString(write.document.metadata), at: 11)
            try insertProjection.bind(write.document.generatedAt, at: 12)
            _ = try insertProjection.step()
            try insertProjection.reset()
        }

        let insertPageLink = try db.prepare("INSERT INTO page_links VALUES (?,?,?,?,?)")
        defer { insertPageLink.finalize() }
        for write in visibleWrites {
            let fromSlug = normalizeProjectionSlugPath(write.slug)
            let links = extractWikiLinkRows(from: write.document.bodyMD, fromSlug: fromSlug, createdAt: write.document.generatedAt)
            for link in links {
                try insertPageLink.bind(link.fromSlug, at: 1)
                try insertPageLink.bind(link.toSlug, at: 2)
                try insertPageLink.bind(link.linkKind, at: 3)
                try insertPageLink.bind(link.anchorText, at: 4)
                try insertPageLink.bind(link.createdAt, at: 5)
                _ = try insertPageLink.step()
                try insertPageLink.reset()
            }
        }

        let insertInvalidation = try db.prepare("INSERT INTO projection_invalidations VALUES (?,?,?,?,?)")
        defer { insertInvalidation.finalize() }
        for invalidation in store.projectionInvalidations.values.sorted(by: { $0.invalidationID < $1.invalidationID }) {
            try insertInvalidation.bind(invalidation.invalidationID, at: 1)
            try insertInvalidation.bind(invalidation.slug, at: 2)
            try insertInvalidation.bind(invalidation.reason, at: 3)
            try insertInvalidation.bind(invalidation.triggeredByPatchID, at: 4)
            try insertInvalidation.bind(invalidation.createdAt, at: 5)
            _ = try insertInvalidation.step()
            try insertInvalidation.reset()
        }

        let insertPatch = try db.prepare("INSERT INTO patch_plans VALUES (?,?,?,?,?,?,?,?,?,?)")
        defer { insertPatch.finalize() }
        for row in store.patchPlans.values.sorted(by: { $0.summary.patchID < $1.summary.patchID }) {
            try insertPatch.bind(row.summary.patchID, at: 1)
            try insertPatch.bind(row.summary.version, at: 2)
            try insertPatch.bind(row.summary.patchKind.rawValue, at: 3)
            try insertPatch.bind(row.summary.generatedAt, at: 4)
            try insertPatch.bind(row.status.rawValue, at: 5)
            try insertPatch.bind(store.pendingReviewCount(row.summary.patchID) ?? 0, at: 6)
            try insertPatch.bind(row.summary.verification.riskLevel.rawValue, at: 7)
            try insertPatch.bind(row.summary.verification.disposition.rawValue, at: 8)
            try insertPatch.bind(row.summary.verification.requiresHumanApproval ? 1 : 0, at: 9)
            try insertPatch.bind(try jsonString(row.summary.verification.reasons), at: 10)
            _ = try insertPatch.step()
            try insertPatch.reset()
        }

        let insertLog = try db.prepare("INSERT INTO operation_logs VALUES (?,?,?,?)")
        defer { insertLog.finalize() }
        for entry in store.operationLogs.values.sorted(by: { $0.logID < $1.logID }) {
            try insertLog.bind(entry.logID, at: 1)
            try insertLog.bind(entry.occurredAt, at: 2)
            try insertLog.bind(entry.opKind, at: 3)
            try insertLog.bind(entry.summary, at: 4)
            _ = try insertLog.step()
            try insertLog.reset()
        }

        let insertSearch = try db.prepare("INSERT INTO search_docs VALUES (?,?,?,?,?,?,?,?,?)")
        defer { insertSearch.finalize() }
        for doc in store.searchDocs.values.sorted(by: { $0.docID < $1.docID }) {
            let metadataText = doc.metadata.keys.sorted().map { key in
                let value = doc.metadata[key] ?? ""
                return "\(key) \(value)"
            }.joined(separator: " ")

            // The mirror is a rebuildable read model, not the canonical
            // knowledge journal. Store searchable text once in canonical
            // composition so unicode61 sees the same scalar form used by
            // SearchText. The FTS table indexes this external content instead
            // of owning a private copy of the same body.
            try insertSearch.bind(doc.docID, at: 1)
            try insertSearch.bind(doc.docKind, at: 2)
            try insertSearch.bind(doc.subjectKind, at: 3)
            try insertSearch.bind(doc.subjectID, at: 4)
            try insertSearch.bind(doc.projectionSlug, at: 5)
            try insertSearch.bind(doc.title.precomposedStringWithCanonicalMapping, at: 6)
            try insertSearch.bind(doc.body.precomposedStringWithCanonicalMapping, at: 7)
            try insertSearch.bind(try jsonString(doc.metadata), at: 8)
            try insertSearch.bind(metadataText.precomposedStringWithCanonicalMapping, at: 9)
            _ = try insertSearch.step()
            try insertSearch.reset()
        }

        // search_docs is rebuilt in the same transaction, so one explicit FTS
        // rebuild is simpler and less error-prone than trigger maintenance.
        try db.exec("INSERT INTO search_docs_fts(search_docs_fts) VALUES('rebuild');")
    }
}

package func mirrorCounts(at path: URL) throws -> [String: Int] {
    guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
    let db = try SQLiteDatabase(path: path, readOnly: true)
    let tables = [
        "source_receipts",
        "source_fragments",
        "authority_records",
        "claims",
        "evidence",
        "claim_evidence",
        "review_items",
        "projection_docs",
        "page_links",
        "projection_invalidations",
        "patch_plans",
        "operation_logs",
        "search_docs",
    ]
    var output: [String: Int] = [:]
    for table in tables {
        output[table] = try db.scalarInt("SELECT COUNT(*) FROM \(table);")
    }
    return output
}
