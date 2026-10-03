import Foundation
import KnowledgeCore

/// The per-record JSON view of canonical state, written on request.
///
/// Materialization used to write this tree into the vault on every apply. No
/// code path ever read it back — the journal is canonical, the mirror answers
/// queries, and the human-facing surface is the wiki pages plus `index.md` and
/// `log.md` — so it cost one file per record per commit and bought nothing.
/// It stays available as an explicit snapshot for inspection and for tools that
/// want the state as plain files.
package enum VaultRecordSnapshot {
    package static func files(for store: KnowledgeStore, authorityYAML: (AuthorityRecord) -> String) throws -> [String: Data] {
        var output: [String: Data] = [:]

        func putJSON(_ path: String, _ payload: some Encodable) throws {
            output[path] = try CanonicalJSON.data(for: payload) + Data([0x0a])
        }

        for source in store.sources.values.sorted(by: { $0.sourceID < $1.sourceID }) {
            try putJSON("records/sources/\(source.sourceID).json", source)
        }
        for fragment in store.sourceFragments.values.sorted(by: { $0.fragmentID < $1.fragmentID }) {
            try putJSON("records/fragments/\(fragment.sourceID)/\(fragment.fragmentID).json", fragment)
        }
        for evidence in store.evidence.values.sorted(by: { $0.evidenceID < $1.evidenceID }) {
            try putJSON("records/evidence/\(evidence.sourceID)/\(evidence.evidenceID).json", evidence)
        }
        for claim in store.claims.values.sorted(by: { $0.claimID < $1.claimID }) {
            try putJSON("records/claims/\(claim.subjectKind)/\(claim.subjectID)/\(claim.claimID).json", claim)
        }
        for edge in store.claimEvidence {
            try putJSON("records/claim_evidence/\(edge.claimID)/\(edge.evidenceID).json", edge)
        }
        for review in store.reviewItems.values.sorted(by: { $0.reviewID < $1.reviewID }) {
            try putJSON("records/reviews/\(review.reviewID).json", review)
        }
        for invalidation in store.projectionInvalidations.values.sorted(by: { $0.invalidationID < $1.invalidationID }) {
            try putJSON("records/invalidations/\(invalidation.slug)/\(invalidation.invalidationID).json", invalidation)
        }
        for record in store.authorityRecords.values.sorted(by: { $0.recordID < $1.recordID }) {
            let path = "records/authority/\(record.recordType)/\(record.subjectKind)_\(record.subjectID)/\(record.recordID).yaml"
            let content = authorityYAML(record)
            output[path] = Data((content + (content.hasSuffix("\n") ? "" : "\n")).utf8)
        }

        return output
    }
}

extension Vault {
    /// Re-checks every approved patch's raw evidence against the journal.
    ///
    /// Loading state no longer digests raw captures, so this is where a deleted
    /// or edited capture is found. Returns one message per problem rather than
    /// throwing on the first, so a report can list everything that needs fixing.
    package func verifyRawEvidence() throws -> [String] {
        let report = try loadStoreFromJournal().report
        var problems: [String] = []
        for patchID in report.approvedPatchIDs {
            guard let plan = try loadPatchPlan(patchID: patchID) else {
                problems.append("approved patch `\(patchID)` has no plan in the journal")
                continue
            }
            for source in plan.sourceReceipts {
                let rawURL = root.appendingPathComponent(source.rawRelpath)
                guard FileManager.default.fileExists(atPath: rawURL.path) else {
                    problems.append("missing raw evidence `\(source.rawRelpath)` for source `\(source.sourceID)`")
                    continue
                }
                guard source.contentHash.hasPrefix("sha256:"), source.contentHash != "sha256:unsupported" else { continue }
                let actual = sha256Prefixed(try Data(contentsOf: rawURL))
                if actual != source.contentHash {
                    problems.append("raw evidence `\(source.rawRelpath)` no longer matches \(source.contentHash)")
                }
            }
        }
        return problems
    }

    /// Writes the per-record JSON/YAML view of current canonical state under
    /// `destination`. The destination must be outside the vault, which owns and
    /// sweeps its own derived tree.
    package func exportRecordSnapshot(to destination: URL) throws {
        let destinationPath = destination.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard destinationPath != rootPath, !destinationPath.hasPrefix(rootPath + "/") else {
            throw ASKError.validation("record snapshot destination must be outside the vault")
        }

        let (store, _) = try loadStoreFromJournal()
        let files = try VaultRecordSnapshot.files(for: store, authorityYAML: renderAuthorityYAML)
        for path in files.keys.sorted() {
            guard let bytes = files[path] else { continue }
            try ASKValidation.requireRelativePath("relative_path", path)
            let url = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
    }
}
