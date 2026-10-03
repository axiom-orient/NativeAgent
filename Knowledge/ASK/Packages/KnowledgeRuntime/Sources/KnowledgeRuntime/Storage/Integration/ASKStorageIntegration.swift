import Foundation
import KnowledgeCore

public enum ASKStorageHealthIntegration {
    public static func makeVaultStorageHealthRuntime(root: URL) -> ASKStorageHealthRuntime {
        let canonical = ASKVaultCanonicalGenerationReader(root: root)
        return ASKStorageHealthRuntime(
            canonical: canonical,
            derivedIndexes: [ASKVaultSearchGenerationReader(root: root, canonical: canonical)]
        )
    }
}

public struct ASKVaultCanonicalGenerationReader: ASKCanonicalGenerationContextReading, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func currentGeneration() async throws -> ASKStorageGeneration {
        try await currentGenerationContext().canonicalGeneration
    }

    package func currentGenerationContext() async throws -> ASKStorageGenerationContext {
        let vault = Vault(root: root)
        return try vault.generationContext(
            store: vault.loadStoreFromJournal().store,
            includeMirrorCounts: false
        )
    }
}

public struct ASKVaultSearchGenerationReader: ASKDerivedGenerationContextReading, Sendable {
    public let root: URL
    private let canonical: any ASKCanonicalGenerationReading

    public init(root: URL, canonical: any ASKCanonicalGenerationReading) {
        self.root = root.standardizedFileURL
        self.canonical = canonical
    }

    public var component: ASKDerivedComponent {
        get async { .search }
    }

    public func currentGeneration() async throws -> ASKStorageGeneration? {
        let vault = Vault(root: root)
        let mirrorURL = vault.mirrorURL()
        guard FileManager.default.fileExists(atPath: mirrorURL.path) else { return nil }

        let expected = try await canonical.currentGeneration()
        let store = try vault.loadStoreFromJournal().store
        return try await currentGeneration(context: ASKStorageGenerationContext(
            canonicalGeneration: expected,
            searchDocCount: store.searchDocs.count,
            mirrorCounts: nil
        ))
    }

    package func currentGeneration(context: ASKStorageGenerationContext) async throws -> ASKStorageGeneration? {
        let vault = Vault(root: root)
        let mirrorURL = vault.mirrorURL()
        guard FileManager.default.fileExists(atPath: mirrorURL.path) else { return nil }

        guard let searchDocCount = context.searchDocCount else {
            return try await currentGeneration()
        }

        let expected = context.canonicalGeneration
        let counts: [String: Int]
        do {
            counts = try mirrorCounts(at: vault.validatedVaultURL(mirrorURL))
            guard let marker = try vault.readGenerationMarker(),
                  marker.canonicalGeneration.value == expected.value,
                  marker.searchDocCount == searchDocCount else {
                return staleGeneration(expected: expected)
            }
        } catch {
            return corruptGeneration(expected: expected)
        }
        let mirrorSearchCount = counts["search_docs"] ?? counts["search_docs_fts"]
        guard let mirrorSearchCount else {
            return corruptGeneration(expected: expected)
        }
        guard mirrorSearchCount == searchDocCount else {
            return staleGeneration(expected: expected)
        }
        return ASKStorageGeneration(component: .search, value: expected.value, updatedAt: expected.updatedAt)
    }

    public func rebuild(to canonicalGeneration: ASKStorageGeneration) async throws -> ASKStorageGeneration {
        _ = try Vault(root: root).rebuild()
        return ASKStorageGeneration(component: .search, value: canonicalGeneration.value, updatedAt: canonicalGeneration.updatedAt)
    }

    private func staleGeneration(expected: ASKStorageGeneration) -> ASKStorageGeneration {
        ASKStorageGeneration(component: .search, value: max(0, expected.value - 1), updatedAt: expected.updatedAt)
    }

    private func corruptGeneration(expected: ASKStorageGeneration) -> ASKStorageGeneration {
        ASKStorageGeneration(component: .search, value: expected.value + 1, updatedAt: expected.updatedAt)
    }
}


package struct ASKVaultGenerationMarker: Codable, Sendable, Equatable, ASKValidatable {
    /// The single supported generation identity schema.
    package static let currentSchemaVersion = 2

    package var schemaVersion: Int
    package var canonicalGeneration: ASKStorageGeneration
    package var searchDocCount: Int?
    package var mirrorCounts: [String: Int]?

    package init(
        schemaVersion: Int = ASKVaultGenerationMarker.currentSchemaVersion,
        canonicalGeneration: ASKStorageGeneration,
        searchDocCount: Int?,
        mirrorCounts: [String: Int]?
    ) {
        self.schemaVersion = schemaVersion
        self.canonicalGeneration = canonicalGeneration
        self.searchDocCount = searchDocCount
        self.mirrorCounts = mirrorCounts
    }

    package init(context: ASKStorageGenerationContext) {
        self.init(
            canonicalGeneration: context.canonicalGeneration,
            searchDocCount: context.searchDocCount,
            mirrorCounts: context.mirrorCounts
        )
    }

    package func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ASKError.validation("unsupported vault generation schema; expected \(Self.currentSchemaVersion)")
        }
    }

    package var context: ASKStorageGenerationContext {
        ASKStorageGenerationContext(
            canonicalGeneration: canonicalGeneration,
            searchDocCount: searchDocCount,
            mirrorCounts: mirrorCounts
        )
    }
}

package struct ASKVaultCanonicalSnapshot: Encodable, Sendable {
    var approvedPatchIDs: [String]
    var rejectedPatchIDs: [String]
    var pendingPatchIDs: [String]
    var authorityRecordIDs: [String]
    var projectionSlugs: [String]
    var visibleProjectionSlugs: [String]
    var searchDocIDs: [String]
    var files: [String]

    package init(_ state: VaultDumpState) throws {
        self.approvedPatchIDs = state.approvedPatchIDs.sorted()
        self.rejectedPatchIDs = state.rejectedPatchIDs.sorted()
        self.pendingPatchIDs = state.pendingPatchIDs.sorted()
        self.authorityRecordIDs = state.authorityRecords.keys.sorted()
        self.projectionSlugs = state.projectionStates.keys.sorted()
        self.visibleProjectionSlugs = state.visibleProjections.keys.sorted()
        self.searchDocIDs = state.searchDocs.keys.sorted()
        self.files = state.files.sorted()
    }
}

package enum ASKStorageGenerationHasher {
    package static func value(for data: Data) -> Int {
        let digest = ASKSHA256.digest(data)
        let folded = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(folded % UInt64(Int32.max - 1)) + 1
    }

    package static func updatedAt(under root: URL) throws -> String {
        let newest = try newestModificationDate(under: root) ?? Date(timeIntervalSince1970: 0)
        return formatted(newest)
    }

    package static func formatted(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt).format(date)
    }

    /// Same value as `updatedAt(under:)` for a walk the caller already did.
    /// Hidden entries stay excluded, matching the enumerator's `skipsHiddenFiles`.
    package static func updatedAt(entries: [PersistenceFileEntry]) -> String {
        let newest = entries
            .filter { !$0.relativePath.split(separator: "/").contains { $0.hasPrefix(".") } }
            .compactMap(\.modifiedAt)
            .max()
        return formatted(newest ?? Date(timeIntervalSince1970: 0))
    }

    private static func newestModificationDate(under root: URL) throws -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ASKError.apply("unable to enumerate storage generation root `\(root.path)`")
        }
        var newest: Date?
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
            if let currentNewest = newest {
                if modified > currentNewest { newest = modified }
            } else {
                newest = modified
            }
        }
        return newest
    }
}
