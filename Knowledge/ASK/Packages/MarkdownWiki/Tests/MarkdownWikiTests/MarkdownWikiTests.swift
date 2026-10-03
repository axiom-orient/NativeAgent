import Foundation
import Testing
@testable import MarkdownWiki

struct MarkdownWikiTests {
    @Test
    func pathPolicyRejectsTraversalAndAbsolutePaths() {
        #expect(throws: ASKMarkdownPathError.invalidPath("../outside.md")) {
            try ASKMarkdownPathPolicy.normalize("../outside.md")
        }
        #expect(throws: ASKMarkdownPathError.invalidPath("/absolute.md")) {
            try ASKMarkdownPathPolicy.normalize("/absolute.md")
        }
    }

    @Test
    func markdownTitleUsesFirstHeading() {
        #expect(ASKMarkdownSupport.title(from: "# Title\n\nBody", fallback: "Fallback") == "Title")
    }

    @Test
    func bootstrapCreatesCanonicalLayoutAndSeedPages() throws {
        try withTemporaryDirectory { root in
            let snapshot = try ASKMarkdownWikiService().bootstrap(root: root)

            #expect(snapshot.layout.rawDirectory == "raw")
            #expect(snapshot.wikiPages.map(\.path) == ["wiki/index.md"])
            #expect(snapshot.schemaFiles.map(\.path) == ["schema/ASK_LLM_WIKI.md"])
            #expect(snapshot.logFiles.map(\.path) == ["logs/log.md"])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("raw").path))
        }
    }

    @Test
    func bootstrapAllowsCallerOwnedRootSymlink() throws {
        #if os(Windows)
        return
        #else
        try withTemporaryDirectory { container in
            let target = container.appendingPathComponent("target", isDirectory: true)
            let root = container.appendingPathComponent("root", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)

            let snapshot = try ASKMarkdownWikiService().bootstrap(root: root)

            #expect(snapshot.wikiPages.map(\.path) == ["wiki/index.md"])
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("wiki/index.md").path))
        }
        #endif
    }

    @Test
    func bootstrapRejectsManagedSymlinkBeforeWriting() throws {
        #if os(Windows)
        return
        #else
        try withTemporaryDirectory { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("bootstrap-outside-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("wiki"),
                withDestinationURL: outside
            )

            #expect(throws: ASKMarkdownWikiError.outsideRoot("wiki")) {
                try ASKMarkdownWikiService().bootstrap(root: root)
            }
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("index.md").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw").path))
        }
        #endif
    }

    @Test
    func bootstrapRejectsManagedSymlinkAliasInsideRoot() throws {
        #if os(Windows)
        return
        #else
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("wiki"),
                withDestinationURL: root.appendingPathComponent("raw")
            )

            #expect(throws: ASKMarkdownWikiError.outsideRoot("wiki")) {
                try ASKMarkdownWikiService().bootstrap(root: root)
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/index.md").path))
        }
        #endif
    }

    @Test
    func danglingManagedSymlinkCannotBeTreatedAsMissingPath() throws {
        #if os(Windows)
        return
        #else
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("wiki"), withIntermediateDirectories: true)
            let missingTarget = root.appendingPathComponent("missing-target.md")
            let dangling = root.appendingPathComponent("wiki/dangling.md")
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missingTarget)

            let service = ASKMarkdownWikiService()
            #expect(throws: ASKMarkdownWikiError.outsideRoot("wiki/dangling.md")) {
                try service.writeWikiPage(root: root, relativePath: "wiki/dangling.md", content: "# Escaped")
            }
            #expect(!FileManager.default.fileExists(atPath: missingTarget.path))
        }
        #endif
    }

    @Test
    func descriptorBoundMutationSurvivesManagedAncestorReplacement() throws {
        #if os(Windows)
        return
        #else
        try withTemporaryDirectory { root in
            let projects = root.appendingPathComponent("wiki/projects", isDirectory: true)
            let heldProjects = root.appendingPathComponent("wiki/projects-held", isDirectory: true)
            let outside = root.deletingLastPathComponent().appendingPathComponent("mutation-outside-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

            let hookState = MutationHookState()
            let service = ASKMarkdownWikiService {
                hookState.invoked = true
                try? FileManager.default.moveItem(at: projects, to: heldProjects)
                try? FileManager.default.createSymbolicLink(
                    at: projects,
                    withDestinationURL: outside
                )
            }

            _ = try service.writeWikiPage(
                root: root,
                relativePath: "wiki/projects/lesson.md",
                content: "# Descriptor bound"
            )

            #expect(hookState.invoked)
            #expect(FileManager.default.fileExists(atPath: heldProjects.appendingPathComponent("lesson.md").path))
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("lesson.md").path))
        }
        #endif
    }

    @Test
    func rollbackLeavesDifferentConcurrentContentUntouched() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)
            try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("raw/invalid.md"))
            let page = root.appendingPathComponent("wiki/index.md")
            let concurrentContent = "# Concurrent writer"

            let mutatingService = ASKMarkdownWikiService(
                mutationHook: {},
                postWriteHook: {
                    try? concurrentContent.write(to: page, atomically: true, encoding: .utf8)
                }
            )

            #expect(throws: ASKMarkdownWikiError.unreadableFile("raw/invalid.md")) {
                try mutatingService.writeWikiPage(
                    root: root,
                    relativePath: "wiki/index.md",
                    content: "# Attempted write"
                )
            }
            #expect(try String(contentsOf: page, encoding: .utf8) == concurrentContent)
        }
    }

    @Test
    func writeBoundaryAllowsOnlyWikiMarkdown() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)

            #expect(throws: ASKMarkdownWikiError.outsideWikiWriteBoundary("raw/source.md")) {
                try service.writeWikiPage(root: root, relativePath: "raw/source.md", content: "# Source")
            }
            #expect(throws: ASKMarkdownWikiError.markdownWriteRequired("wiki/page.txt")) {
                try service.writeWikiPage(root: root, relativePath: "wiki/page.txt", content: "text")
            }

            let snapshot = try service.writeWikiPage(
                root: root,
                relativePath: "wiki/projects/a.md",
                content: "# Project A\n\nVerified content."
            )
            #expect(snapshot.wikiPages.map(\.path).contains("wiki/projects/a.md"))
            #expect(try service.readText(root: root, relativePath: "wiki/projects/a.md") == "# Project A\n\nVerified content.")
        }
    }

    @Test
    func createRejectsExistingPageExplicitly() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)

            #expect(throws: ASKMarkdownWikiError.pageAlreadyExists("wiki/index.md")) {
                try service.createWikiPage(root: root, relativePath: "wiki/index.md", content: "# Replacement")
            }
        }
    }

    @Test
    func readCanExcludeLogs() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)

            #expect(throws: ASKMarkdownWikiError.invalidPath("logs/log.md")) {
                try service.readText(root: root, relativePath: "logs/log.md", allowLogs: false)
            }
        }
    }

    /// A path that resolves but has no file is a different failure from a file
    /// whose bytes are not text, and the caller fixes each one differently.
    @Test
    func readTextSeparatesMissingFileFromInvalidEncoding() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)

            #expect(throws: ASKMarkdownWikiError.missingFile("wiki/notes/absent.md")) {
                try service.readText(root: root, relativePath: "wiki/notes/absent.md")
            }

            let invalid = root.appendingPathComponent("wiki/notes/invalid.md")
            try FileManager.default.createDirectory(
                at: invalid.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0xFF, 0xFE, 0xFD]).write(to: invalid)
            #expect(throws: ASKMarkdownWikiError.unreadableFile("wiki/notes/invalid.md")) {
                try service.readText(root: root, relativePath: "wiki/notes/invalid.md")
            }
        }
    }

    @Test
    func snapshotSurfacesInvalidUTF8InsteadOfCreatingEmptyEntry() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)
            try Data([0xFF, 0xFE, 0xFD]).write(to: root.appendingPathComponent("raw/invalid.md"))

            #expect(throws: ASKMarkdownWikiError.unreadableFile("raw/invalid.md")) {
                try service.snapshot(root: root)
            }
        }
    }

    @Test
    func failedWriteRestoresPreviousPageContent() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)
            let pageURL = root.appendingPathComponent("wiki/index.md")
            let original = try Data(contentsOf: pageURL)
            try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("raw/invalid.md"))

            #expect(throws: ASKMarkdownWikiError.unreadableFile("raw/invalid.md")) {
                try service.writeWikiPage(root: root, relativePath: "wiki/index.md", content: "# Replacement")
            }
            #expect(try Data(contentsOf: pageURL) == original)
        }
    }

    @Test
    func failedCreateRemovesNewPage() throws {
        try withTemporaryDirectory { root in
            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)
            try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("raw/invalid.md"))
            let newPageURL = root.appendingPathComponent("wiki/new.md")

            #expect(throws: ASKMarkdownWikiError.unreadableFile("raw/invalid.md")) {
                try service.createWikiPage(root: root, relativePath: "wiki/new.md", content: "# New")
            }
            #expect(!FileManager.default.fileExists(atPath: newPageURL.path))
        }
    }

    @Test
    func symlinkCannotEscapeWikiRoot() throws {
        #if os(Windows)
        return
        #else
        try withTemporaryDirectory { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

            let service = ASKMarkdownWikiService()
            _ = try service.bootstrap(root: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("wiki/external"),
                withDestinationURL: outside
            )

            #expect(throws: ASKMarkdownWikiError.outsideRoot("wiki/external/escaped.md")) {
                try service.writeWikiPage(
                    root: root,
                    relativePath: "wiki/external/escaped.md",
                    content: "# Escaped"
                )
            }
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.md").path))
        }
        #endif
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("markdown-wiki-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}

private final class MutationHookState: @unchecked Sendable {
    var invoked = false
}
