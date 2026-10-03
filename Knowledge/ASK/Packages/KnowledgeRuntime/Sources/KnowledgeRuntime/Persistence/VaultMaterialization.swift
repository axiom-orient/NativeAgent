import Foundation
import KnowledgeCore

extension Vault {
    package func dumpState() throws -> VaultDumpState {
        let (store, report) = try loadStoreFromJournal()
        return try dumpState(store: store, report: report)
    }

    /// Same snapshot as `dumpState()` for a store the caller already holds.
    /// Materialization uses this so writing the generation marker does not
    /// re-read the whole journal it just materialized from.
    package func dumpState(
        store: KnowledgeStore,
        report: RebuildReport,
        entries: [PersistenceFileEntry]? = nil
    ) throws -> VaultDumpState {
        let counts = try mirrorCounts(at: mirrorURL())

        let authorityPairs: [(String, AuthorityStateSnapshot)] = store.authorityRecords.keys.sorted().compactMap { recordID in
            guard let record = store.authorityRecords[recordID] else { return nil }
            return (
                recordID,
                AuthorityStateSnapshot(
                    approvalState: record.approvalState,
                    effectiveFrom: record.effectiveFrom,
                    effectiveTo: record.effectiveTo,
                    supersedesID: record.supersedesID
                )
            )
        }
        let authorityRecords = Dictionary(uniqueKeysWithValues: authorityPairs)

        let projectionStatePairs: [(String, [ProjectionState])] = store.projections.keys.sorted().map { slug in
            (slug, store.projectionStates(slug: slug))
        }
        let projectionStates = Dictionary(uniqueKeysWithValues: projectionStatePairs)

        let visibleProjectionPairs: [(String, VisibleProjectionSnapshot)] = store.visibleProjectionWrites().map { write in
            (
                write.slug,
                VisibleProjectionSnapshot(
                    state: write.state,
                    title: write.document.title,
                    space: write.document.metadata.projectionSpace
                )
            )
        }
        let visibleProjections = Dictionary(uniqueKeysWithValues: visibleProjectionPairs)

        let walked = try entries?.map(\.relativePath) ??
            (FileManager.default.fileExists(atPath: root.path) ? allFiles() : [])
        let files = try walked
            .filter { try isTransientPath($0) == false }
            .sorted()

        return VaultDumpState(
            approvedPatchIDs: report.approvedPatchIDs,
            rejectedPatchIDs: report.rejectedPatchIDs,
            pendingPatchIDs: report.pendingPatchIDs,
            authorityRecords: authorityRecords,
            projectionStates: projectionStates,
            visibleProjections: visibleProjections,
            searchDocs: store.searchDocs,
            mirrorCounts: counts,
            files: files
        )
    }

    package func materializeFromStore(_ store: KnowledgeStore, report: RebuildReport? = nil) throws {
        var plan = DerivedOutputPlan()

        let visibleWrites = store.visibleProjectionWrites()
        for write in visibleWrites {
            try plan.putText(projectionRelativePath(for: write), content: projectionPageContent(write))
        }

        try plan.putText("index.md", content: indexContent(visibleWrites))
        try plan.putText("log.md", content: logContent(store: store))

        try syncDerivedOutputs(plan)

        // The mirror is rebuilt with plain INSERTs into a fresh schema, so the
        // previous database file must be gone before it is rewritten.
        try removeGeneratedFile("mirror/knowledge.sqlite")
        try rebuildMirror(at: mirrorURL(), store: store)
        try writeGenerationMarker(store: store, report: report)
    }

    package func projectionRelativePath(for write: ProjectionWrite) -> String {
        KnowledgeRuntime.projectionRelativePath(slug: write.slug, metadata: write.document.metadata)
    }

    package func projectionURL(for write: ProjectionWrite) -> URL {
        root.appendingPathComponent(projectionRelativePath(for: write))
    }

    package func projectionPageContent(_ write: ProjectionWrite) -> String {
        let metadata: [String: Any] = [
            "version": write.document.version,
            "projection_state": write.state.rawValue,
            "slug": write.slug,
            "title": write.document.title,
            "projection_kind": write.document.metadata.projectionKind.rawValue,
            "projection_family": projectionFamily(for: write.document.metadata, slug: write.slug).rawValue,
            "projection_space": write.document.metadata.projectionSpace.rawValue,
            "subject_kind": write.document.metadata.subjectKind,
            "subject_id": write.document.metadata.subjectID,
            "authority_ids": write.document.metadata.authorityIDs,
            "source_ids": write.document.metadata.sourceIDs,
            "claim_ids": write.document.metadata.claimIDs,
            "historical": write.document.metadata.historical,
            "approval_required": write.document.metadata.approvalRequired,
            "generated_from_hash": write.document.generatedFromHash,
            "generated_at": write.document.generatedAt,
        ]
        return renderFrontmatter(metadata, body: write.document.bodyMD)
    }

    package func indexContent(_ writes: [ProjectionWrite]) -> String {
        var lines = ["# Index", ""]
        if writes.isEmpty {
            lines.append("_No projection pages materialized._")
        } else {
            let orderedFamilies: [ProjectionFamily] = [.current, .entity, .topic, .source, .playbook, .casebook, .query, .other]
            let grouped = Dictionary(grouping: writes) { write in
                projectionFamily(for: write.document.metadata, slug: write.slug)
            }
            for family in orderedFamilies {
                guard let familyWrites = grouped[family], !familyWrites.isEmpty else { continue }
                lines.append("## \(familyHeading(family))")
                lines.append("")
                for write in familyWrites.sorted(by: { $0.slug < $1.slug }) {
                    let relative = projectionURL(for: write).path.replacingOccurrences(of: root.path + "/", with: "")
                    var summary = write.document.bodyMD.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
                    if summary.count > 96 {
                        summary = String(summary.prefix(96)) + "…"
                    }
                    let sourceCount = write.document.metadata.sourceIDs.count
                    let authorityCount = write.document.metadata.authorityIDs.count
                    let claimCount = write.document.metadata.claimIDs.count
                    let linkCount = extractWikiLinkRows(from: write.document.bodyMD, fromSlug: normalizeProjectionSlugPath(write.slug), createdAt: write.document.generatedAt).count
                    lines.append("- [\(write.document.title)](\(relative)) | slug=\(write.slug) | family=\(family.rawValue) | sources=\(sourceCount) | authority=\(authorityCount) | claims=\(claimCount) | links=\(linkCount) | generated_at=\(write.document.generatedAt)")
                    if !summary.isEmpty {
                        lines.append("  summary: \(summary)")
                    }
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    package func logContent(store: KnowledgeStore) -> String {
        var lines = ["# Log", ""]
        let entries = OperationLogEntry.canonicallyOrdered(store.operationLogs.values)
        if entries.isEmpty {
            lines.append("_No operations logged._")
        } else {
            for entry in entries {
                lines.append("- \(entry.occurredAt) | \(entry.opKind) | \(entry.logID) | \(entry.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    package func renderAuthorityYAML(_ record: AuthorityRecord) -> String {
        var lines = [
            "version: \(yamlDoubleQuotedScalar(record.version))",
            "record_id: \(yamlDoubleQuotedScalar(record.recordID))",
            "record_type: \(yamlDoubleQuotedScalar(record.recordType))",
            "subject_kind: \(yamlDoubleQuotedScalar(record.subjectKind))",
            "subject_id: \(yamlDoubleQuotedScalar(record.subjectID))",
            "fact_scope_key: \(yamlDoubleQuotedScalar(record.factScopeKey))",
            "approval_state: \(yamlDoubleQuotedScalar(record.approvalState.rawValue))",
            "value_fields:",
        ]
        for key in record.valueFields.keys.sorted() {
            let value = record.valueFields[key] ?? ""
            lines.append("  \(yamlDoubleQuotedScalar(key)): \(yamlDoubleQuotedScalar(value))")
        }
        lines.append("effective_from: \(yamlDoubleQuotedScalar(record.effectiveFrom))")
        lines.append("effective_to: \(jsonLiteral(record.effectiveTo))")
        lines.append("approved_by: \(jsonLiteral(record.approvedBy))")
        lines.append("supersedes_id: \(jsonLiteral(record.supersedesID))")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension Vault {
    package func readGenerationMarker() throws -> ASKVaultGenerationMarker? {
        let url = generationMarkerURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try CanonicalJSON.load(ASKVaultGenerationMarker.self, from: url)
    }

    package func writeGenerationMarker(store: KnowledgeStore? = nil, report: RebuildReport? = nil) throws {
        let context: ASKStorageGenerationContext
        if let store {
            context = try generationContext(store: store)
        } else {
            context = try generationContext(store: loadStoreFromJournal().store)
        }
        try writeJSONFile(generationMarkerURL(), payload: ASKVaultGenerationMarker(context: context))
    }

    /// The canonical generation is a function of the journal alone.
    ///
    /// It used to hash the whole file list, which meant regenerating derived
    /// output changed the *canonical* generation and every commit had to walk the
    /// entire tree to compute it. Derived components carry their own generation —
    /// that is what `ASKStorageGenerationContext` is for — and drift in derived
    /// files is repaired by `rebuild()`, which rewrites whatever differs.
    package func generationContext(store: KnowledgeStore, includeMirrorCounts: Bool = true) throws -> ASKStorageGenerationContext {
        let identity = try journalIdentity()
        let generation = ASKStorageGeneration(
            component: .canonical,
            value: ASKStorageGenerationHasher.value(for: Data(identity.fingerprint.utf8)),
            updatedAt: ASKStorageGenerationHasher.formatted(identity.modifiedAt)
        )
        return ASKStorageGenerationContext(
            canonicalGeneration: generation,
            searchDocCount: store.searchDocs.count,
            mirrorCounts: includeMirrorCounts ? try mirrorCounts(at: mirrorURL()) : nil
        )
    }
}

private func familyHeading(_ family: ProjectionFamily) -> String {
    switch family {
    case .current: return "Current"
    case .entity: return "Entities"
    case .topic: return "Topics"
    case .source: return "Sources"
    case .playbook: return "Playbook"
    case .casebook: return "Casebook"
    case .query: return "Queries"
    case .other: return "Other"
    }
}
