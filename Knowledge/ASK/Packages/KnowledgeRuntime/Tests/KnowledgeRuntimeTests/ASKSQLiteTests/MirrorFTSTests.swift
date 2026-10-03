import Foundation
import Testing
@testable import KnowledgeCore
@testable import KnowledgeRuntime

struct ASKSQLiteTests {
    @Test
    func mirrorFTSCanReturnProjectionCandidate() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-sqlite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let mirrorURL = tmpRoot.appendingPathComponent("mirror.sqlite")

        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .currentSnapshot,
            projectionSpace: .wiki,
            subjectKind: "topic",
            subjectID: "ask",
            authorityIDs: ["auth_current"],
            sourceIDs: ["src_demo"],
            claimIDs: ["cl_demo"],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "ask-overview",
            title: "ASK Overview",
            bodyMD: "ASK is a file-backed knowledge compiler optimized for grounded projection rebuilds.",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-07T10:00:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        let write = ProjectionWrite(slug: "ask-overview", state: .accepted, document: document)
        store.replaceProjectionWrites(slug: write.slug, writes: [write])
        try store.rebuildSearchIndex()
        try rebuildMirror(at: mirrorURL, store: store)

        let hits = try searchMirrorCandidates(at: mirrorURL, query: "knowledge compiler", limit: 10)
        #expect(!hits.isEmpty)
        #expect(hits.first?.row.projectionSlug == "ask-overview")
        #expect(hits.first?.row.title == "ASK Overview")
    }

    @Test
    func mirrorFTSKeepsSnippetForSimpleBody() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-sqlite-snippet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let mirrorURL = tmpRoot.appendingPathComponent("mirror.sqlite")

        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .currentSnapshot,
            projectionSpace: .wiki,
            subjectKind: "topic",
            subjectID: "search",
            authorityIDs: ["auth_current"],
            sourceIDs: ["src_snippet"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "search-snippet",
            title: "Search Snippet",
            bodyMD: "knowledge compiler",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T10:30:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        let write = ProjectionWrite(slug: document.slug, state: .accepted, document: document)
        store.replaceProjectionWrites(slug: write.slug, writes: [write])
        try store.rebuildSearchIndex()
        try rebuildMirror(at: mirrorURL, store: store)

        let hits = try searchMirrorCandidates(at: mirrorURL, query: "knowledge compiler", limit: 5)
        let first = try #require(hits.first)
        #expect(first.row.projectionSlug == "search-snippet")
        #expect(first.snippet.contains("knowledge compiler"))
    }

    @Test
    func mirrorFTSCanHandleNaturalLanguagePunctuation() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-sqlite-punct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let mirrorURL = tmpRoot.appendingPathComponent("mirror.sqlite")

        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .playbookEntry,
            projectionSpace: .playbook,
            subjectKind: "topic",
            subjectID: "bridge",
            authorityIDs: ["auth_current"],
            sourceIDs: ["src_demo"],
            claimIDs: [],
            historical: false,
            approvalRequired: true
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "playbook/bridge-design",
            title: "Bridge design guidance",
            bodyMD: "Use a thin bridge and keep truth ownership in Ask.",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-07T10:30:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        let write = ProjectionWrite(slug: document.slug, state: .accepted, document: document)
        store.replaceProjectionWrites(slug: write.slug, writes: [write])
        try store.rebuildSearchIndex()
        try rebuildMirror(at: mirrorURL, store: store)

        let hits = try searchMirrorCandidates(at: mirrorURL, query: "How should I design the bridge?", limit: 10)
        #expect(!hits.isEmpty)
        #expect(hits.first?.row.projectionSlug == "playbook/bridge-design")
    }

    @Test
    func archiveCleanupHelperSurfacesRemovalFailures() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-cleanup-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try Data("cleanup".utf8).write(to: tmpRoot)

        enum CleanupError: Error {
            case blocked
        }

        #expect(throws: Error.self) {
            try removeArchivePathIfPresent(tmpRoot, label: "test cleanup") { _ in
                throw CleanupError.blocked
            }
        }
    }


    @Test
    func mirrorRebuildExtractsWikiLinksIntoPageLinks() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-sqlite-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let mirrorURL = tmpRoot.appendingPathComponent("mirror.sqlite")

        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .entityOverview,
            projectionSpace: .wiki,
            subjectKind: "project",
            subjectID: "ask",
            authorityIDs: [],
            sourceIDs: ["src_links"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "entities/ask",
            title: "ASK",
            bodyMD: "ASK links to [[topics/file-first]] and [[current/mobile-vault|Mobile Vault]].",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T11:00:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        store.replaceProjectionWrites(
            slug: document.slug,
            writes: [ProjectionWrite(slug: document.slug, state: .accepted, document: document)]
        )
        try store.rebuildSearchIndex()
        try rebuildMirror(at: mirrorURL, store: store)

        let counts = try mirrorCounts(at: mirrorURL)
        #expect(counts["page_links"] == 2)
    }

    @Test
    func decomposedBodyTextIsReachableFromAComposedQuery() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-sqlite-nfd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let mirrorURL = tmpRoot.appendingPathComponent("mirror.sqlite")

        let composedTerm = "지식"
        let decomposedTerm = composedTerm.decomposedStringWithCanonicalMapping
        // Swift compares strings by canonical equivalence; the scalars differ,
        // and it is the scalars that unicode61 indexes.
        #expect(Array(composedTerm.unicodeScalars) != Array(decomposedTerm.unicodeScalars))

        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .currentSnapshot,
            projectionSpace: .wiki,
            subjectKind: "topic",
            subjectID: "nfd",
            authorityIDs: [],
            sourceIDs: ["src_nfd"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "topics/nfd",
            title: "NFD",
            bodyMD: "\(decomposedTerm) 컴파일러",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-04-08T11:00:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        store.replaceProjectionWrites(
            slug: document.slug,
            writes: [ProjectionWrite(slug: document.slug, state: .accepted, document: document)]
        )
        try store.rebuildSearchIndex()
        try rebuildMirror(at: mirrorURL, store: store)

        let hits = try searchMirrorCandidates(at: mirrorURL, query: composedTerm, limit: 10)
        #expect(hits.first?.row.projectionSlug == "topics/nfd")
    }

    @Test
    func mirrorFTSUsesExternalContentWithoutPrivateBodyShadow() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-sqlite-external-content-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let mirrorURL = tmpRoot.appendingPathComponent("mirror.sqlite")

        var store = KnowledgeStore.openInMemory()
        let metadata = ProjectionMetadata(
            projectionKind: .currentSnapshot,
            projectionSpace: .wiki,
            subjectKind: "topic",
            subjectID: "external-content",
            authorityIDs: [],
            sourceIDs: ["src_external_content"],
            claimIDs: [],
            historical: false,
            approvalRequired: false
        )
        var document = ProjectionDocument(
            version: projectionDocumentVersion,
            slug: "topics/external-content",
            title: "External Content",
            bodyMD: "single owner searchable body",
            metadata: metadata,
            generatedFromHash: "",
            generatedAt: "2026-09-11T00:00:00Z"
        )
        document.generatedFromHash = projectionDocumentHash(document)
        store.replaceProjectionWrites(
            slug: document.slug,
            writes: [ProjectionWrite(slug: document.slug, state: .accepted, document: document)]
        )
        try store.rebuildSearchIndex()
        try rebuildMirror(at: mirrorURL, store: store)

        let db = try SQLiteDatabase(path: mirrorURL)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='search_docs_fts_content';") == 0)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM search_docs;") == 1)
        // For an external-content FTS table, rank=1 verifies the index against
        // the content table as well as checking the FTS index structure itself.
        try db.exec("INSERT INTO search_docs_fts(search_docs_fts, rank) VALUES('integrity-check', 1);")

        let hits = try searchMirrorCandidates(at: mirrorURL, query: "searchable body", limit: 5)
        #expect(hits.first?.row.projectionSlug == "topics/external-content")
    }
}
