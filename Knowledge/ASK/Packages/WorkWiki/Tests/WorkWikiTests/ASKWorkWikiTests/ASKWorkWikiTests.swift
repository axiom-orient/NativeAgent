import Foundation
import Testing
import KnowledgeCore
@testable import WorkWiki

struct ASKWorkWikiTests {
    private func withProjectRoot(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-workwiki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ relativePath: String, body: String, in root: URL) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @Test
    func refreshIndexesOnlyConventionalKnowledgeDirectories() throws {
        try withProjectRoot { root in
            try write("wip/research/session-actor.md", body: "# Session Actor\nResearch notes", in: root)
            try write("wip/prepare/session-actor-plan.md", body: "# Session Actor Plan\nPrepare notes", in: root)
            try write("wip/prove/session-actor-proof.md", body: "# Session Actor Proof\nProve notes", in: root)
            try write("wiki/docs/session-actor.md", body: "# Session Actor Docs\nDocs notes", in: root)
            try write("wip/onit/session-actor.txt", body: "OnIt note", in: root)
            try write("notes/random.md", body: "# Ignore me", in: root)
            try write("wiki/docs/diagram.png", body: "not actually png", in: root)

            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()

            #expect(snapshot.counts.research == 1)
            #expect(snapshot.counts.prepare == 1)
            #expect(snapshot.counts.prove == 1)
            #expect(snapshot.counts.docs == 1)
            #expect(snapshot.counts.onit == 1)
            #expect(snapshot.counts.total == 5)
            #expect(!snapshot.indexedPaths.contains("notes/random.md"))
            #expect(!snapshot.indexedPaths.contains("wiki/docs/diagram.png"))
        }
    }

    @Test
    func projectResolutionUsesDeterministicWorkspaceHashSlug() throws {
        try withProjectRoot { root in
            let kernel = ASKWorkWikiKernel(projectRoot: root)
            let first = kernel.resolve()
            let second = kernel.resolve()

            #expect(first == second)
            #expect(first.source == .workspaceHash)
            #expect(first.projectSlug.contains("-"))
            #expect(first.projectRootPath == root.standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }

    @Test
    func statusReportsCrossLayerSearchAsUnsupported() throws {
        try withProjectRoot { root in
            let status = try ASKWorkWikiKernel(projectRoot: root).refresh().status

            let searchCapability = try #require(status.capabilities.first(where: { $0.name == "search" }))
            #expect(searchCapability.support == .unsupported)
            #expect(searchCapability.reason.contains("Cross-layer search"))

            let convergenceCapability = try #require(status.capabilities.first(where: { $0.name == "convergence" }))
            #expect(convergenceCapability.support == .partial)
        }
    }

    @Test
    func refreshProducesDeterministicSummaries() throws {
        try withProjectRoot { root in
            try write("wiki/docs/session-runtime.md", body: "# Session Runtime\nRuntime docs", in: root)
            try write("wip/research/session-actor.md", body: "# Session Actor\nResearch notes", in: root)

            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()

            #expect(snapshot.documents.map(\.relativePath) == [
                "wiki/docs/session-runtime.md",
                "wip/research/session-actor.md"
            ])
            #expect(snapshot.documents.map(\.title) == ["Session Runtime", "Session Actor"])
        }
    }

    @Test
    func knowledgeDocumentLoadsRequestedRelativePathFromSnapshot() throws {
        try withProjectRoot { root in
            try write("wiki/docs/session-runtime.md", body: "# Session Runtime\nRuntime docs", in: root)

            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()
            let document = try snapshot.knowledgeDocument(relativePath: "wiki/docs/session-runtime.md")

            #expect(document.category == .docs)
            #expect(document.title == "Session Runtime")
            #expect(document.body.contains("Runtime docs"))
        }
    }

    @Test
    func knowledgeDocumentRejectsMissingRelativePath() throws {
        try withProjectRoot { root in
            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()

            #expect(throws: ASKError.self) {
                _ = try snapshot.knowledgeDocument(relativePath: "wiki/docs/missing.md")
            }
        }
    }

    @Test
    func knowledgeSearchReturnsCategoryTaggedHits() throws {
        try withProjectRoot { root in
            try write("wip/research/session-actor.md", body: "# Session Actor\nResearch on session actor lifecycle", in: root)
            try write("wiki/docs/session-runtime.md", body: "# Session Runtime\nRuntime docs mention session actor flow", in: root)

            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()
            let search = try snapshot.knowledgeSearch("session actor", limit: 10)

            #expect(search.hits.count == 2)
            #expect(search.hits[0].category == .research)
            #expect(search.hits[0].relativePath == "wip/research/session-actor.md")
            #expect(search.hits[1].category == .docs)
        }
    }

    @Test
    func convergenceGroupsTopicsAcrossPhaseSuffixes() throws {
        try withProjectRoot { root in
            try write("wip/research/session-actor.md", body: "# Session Actor\nResearch", in: root)
            try write("wip/prepare/session-actor-plan.md", body: "# Session Actor Plan\nPrepare", in: root)
            try write("wip/prove/session-actor-proof.md", body: "# Session Actor Proof\nProve", in: root)
            try write("wiki/docs/session-actor.md", body: "# Session Actor\nDocs", in: root)

            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()
            let report = snapshot.convergence()
            let topic = try #require(report.topics.first(where: { $0.topicSlug == "session-actor" }))

            #expect(topic.topicTitle == "Session Actor")
            #expect(topic.researchCount == 1)
            #expect(topic.prepareCount == 1)
            #expect(topic.proveCount == 1)
            #expect(topic.docsCount == 1)
            #expect(topic.coveragePercent == 100)
            #expect(topic.strength == .full)
        }
    }

    @Test
    func convergenceReportsWeakPartialAndFullCoverage() throws {
        try withProjectRoot { root in
            try write("wip/research/alpha.md", body: "# Alpha\nResearch", in: root)
            try write("wip/research/bravo.md", body: "# Bravo\nResearch", in: root)
            try write("wip/prepare/bravo-plan.md", body: "# Bravo Plan\nPrepare", in: root)
            try write("wip/prove/bravo-proof.md", body: "# Bravo Proof\nProve", in: root)
            try write("wip/research/charlie.md", body: "# Charlie\nResearch", in: root)
            try write("wip/prepare/charlie-plan.md", body: "# Charlie Plan\nPrepare", in: root)
            try write("wip/prove/charlie-proof.md", body: "# Charlie Proof\nProve", in: root)
            try write("wiki/docs/charlie.md", body: "# Charlie\nDocs", in: root)

            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()
            let report = snapshot.convergence()

            let alpha = try #require(report.topics.first(where: { $0.topicSlug == "alpha" }))
            let bravo = try #require(report.topics.first(where: { $0.topicSlug == "bravo" }))
            let charlie = try #require(report.topics.first(where: { $0.topicSlug == "charlie" }))

            #expect(alpha.coveragePercent == 25)
            #expect(alpha.strength == .weak)
            #expect(bravo.coveragePercent == 75)
            #expect(bravo.strength == .partial)
            #expect(charlie.coveragePercent == 100)
            #expect(charlie.strength == .full)
        }
    }

    @Test
    func knowledgeSearchRejectsEmptyQuery() throws {
        try withProjectRoot { root in
            let snapshot = try ASKWorkWikiKernel(projectRoot: root).refresh()

            #expect(throws: ASKError.self) {
                _ = try snapshot.knowledgeSearch("   ", limit: 5)
            }
        }
    }

    @Test
    func packageSourceDependsOnlyOnCoreRuntimeAndIndexing() throws {
        let packageRoot = try packageRoot()
        let sourcesRoot = packageRoot.appendingPathComponent("Sources/WorkWiki", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        )
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        #expect(!files.isEmpty)

        let allowed: Set<String> = [
            "import KnowledgeCore",
            "import KnowledgeRuntime",
            "import EvidenceIndex",
        ]
        for file in files.sorted(by: { $0.path < $1.path }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let packageImports = text
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { $0.hasPrefix("import Knowledge") || $0.hasPrefix("import Evidence") }
            #expect(packageImports.allSatisfy { allowed.contains($0) })
        }
    }

    private func packageRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return dir
    }

}
