import Foundation
import Testing
import DocumentCore
@testable import DocumentRuntime

@Test("File-system runtime loader selects scene artifacts and loads the canonical document JSON")
func fileSystemRuntimeLoaderSelectsSceneAndLoadsDocumentJSON() async throws {
    let document = ASKPageDocument(
        id: .init("doc-scene"),
        title: "Scene Doc",
        source: .init(kind: .package),
        sections: [],
        blocks: []
    )
    let scene = ASKCanvasPage(id: .init("scene-1"), elements: [])
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json", scenePath: "scene.json")

    let package = try await withRuntimeFixture(document: document, scene: scene, manifest: manifest) { rootURL in
        try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
    }

    #expect(package.document == document)
    #expect(package.selection == .init(selectedKind: .scene, attemptedKinds: [.scene], selectedPath: "scene.json"))
    guard case .scene(let selectedScene) = package.selectedArtifact else {
        Issue.record("Expected scene payload")
        return
    }
    #expect(selectedScene == scene)
}

@Test("File-system runtime loader falls back to hybrid templates when scene is absent")
func fileSystemRuntimeLoaderSelectsHybridTemplate() async throws {
    let document = ASKPageDocument(
        id: .init("doc-hybrid"),
        title: "Hybrid Doc",
        source: .init(kind: .package),
        sections: [],
        blocks: []
    )
    let manifest = ASKPageRuntimeManifest(
        documentJSONPath: "document.json",
        hybridTemplatePath: "hybrid-template.html",
        fullHTMLPath: "full.html"
    )

    let package = try await withRuntimeFixture(
        document: document,
        hybridTemplateHTML: "<div>{{content}}</div>",
        fullHTML: "<html>fallback</html>",
        manifest: manifest
    ) { rootURL in
        try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
    }

    #expect(package.selection == .init(selectedKind: .hybridTemplate, attemptedKinds: [.scene, .hybridTemplate], selectedPath: "hybrid-template.html"))
    guard case .hybridTemplate(let html) = package.selectedArtifact else {
        Issue.record("Expected hybrid template payload")
        return
    }
    #expect(html == "<div>{{content}}</div>")
}

@Test("File-system runtime loader falls back to full HTML when higher-priority artifacts are absent")
func fileSystemRuntimeLoaderSelectsFullHTML() async throws {
    let document = ASKPageDocument(
        id: .init("doc-html"),
        title: "Full HTML Doc",
        source: .init(kind: .package),
        sections: [],
        blocks: []
    )
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json", fullHTMLPath: "full.html")

    let package = try await withRuntimeFixture(document: document, fullHTML: "<html><body>Full</body></html>", manifest: manifest) { rootURL in
        try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
    }

    #expect(package.selection == .init(selectedKind: .fullHTML, attemptedKinds: [.scene, .hybridTemplate, .fullHTML], selectedPath: "full.html"))
    guard case .fullHTML(let html) = package.selectedArtifact else {
        Issue.record("Expected full HTML payload")
        return
    }
    #expect(html == "<html><body>Full</body></html>")
}

@Test("File-system runtime loader compiles markdown when it is the only available artifact")
func fileSystemRuntimeLoaderCompilesMarkdownFallback() async throws {
    let markdown = "# Runtime Title\n\nHello runtime."
    let manifest = ASKPageRuntimeManifest(
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-markdown"),
            sourceID: .init("src-markdown")
        )
    )

    let package = try await withRuntimeFixture(markdown: markdown, manifest: manifest) { rootURL in
        try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
    }

    #expect(package.selection == .init(selectedKind: .markdown, attemptedKinds: [.scene, .hybridTemplate, .fullHTML, .markdown], selectedPath: "document.md"))
    #expect(package.document.id == .init("doc-markdown"))
    #expect(package.document.title == "Runtime Title")
    #expect(package.document.source.authoritativeMarkdownPath == "document.md")
    guard case .markdown(let selectedMarkdown) = package.selectedArtifact else {
        Issue.record("Expected markdown payload")
        return
    }
    #expect(selectedMarkdown == markdown)
}

@Test("File-system runtime loader also satisfies the document-loader boundary")
func fileSystemRuntimeLoaderConformsToDocumentLoaderBoundary() async throws {
    let markdown = "# Boundary\n\nDoc loader path."
    let manifest = ASKPageRuntimeManifest(
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-boundary"),
            sourceID: .init("src-boundary")
        )
    )

    let loader: any ASKPageDocumentLoader = ASKPageFileSystemRuntimeLoader()
    let document = try await withRuntimeFixture(markdown: markdown, manifest: manifest) { rootURL in
        try await loader.loadDocument(from: .init(rootURL: rootURL))
    }

    #expect(document.id == .init("doc-boundary"))
    #expect(document.title == "Boundary")
}

@Test("File-system runtime loader rejects artifact paths that escape the package root")
func fileSystemRuntimeLoaderRejectsEscapingPaths() async throws {
    let document = ASKPageDocument(
        id: .init("doc-escape"),
        title: "Escaped",
        source: .init(kind: .package),
        sections: [],
        blocks: []
    )
    let scene = ASKCanvasPage(id: .init("scene-escape"), elements: [])
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json", scenePath: "../scene.json")

    do {
        _ = try await withRuntimeFixture(document: document, scene: scene, manifest: manifest) { rootURL in
            try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        }
        Issue.record("Expected path traversal failure")
    } catch let error as ASKPageRuntimeError {
        guard case .filePathEscapesRoot(let path) = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
        #expect(path == "../scene.json")
    }
}

@Test("File-system runtime loader rejects scene packages without a canonical document source")
func fileSystemRuntimeLoaderRejectsSceneWithoutCanonicalDocument() async throws {
    let scene = ASKCanvasPage(id: .init("scene-orphan"), elements: [])
    let manifest = ASKPageRuntimeManifest(scenePath: "scene.json")

    do {
        _ = try await withRuntimeFixture(scene: scene, manifest: manifest) { rootURL in
            try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        }
        Issue.record("Expected missing canonical document failure")
    } catch let error as ASKPageRuntimeError {
        guard case .missingCanonicalDocument = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
    }
}

@Test("File-system runtime loader rejects unsupported manifest versions")
func fileSystemRuntimeLoaderRejectsUnsupportedManifestVersions() async throws {
    let manifest = ASKPageRuntimeManifest(
        version: 99,
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-version"),
            sourceID: .init("src-version")
        )
    )

    do {
        _ = try await withRuntimeFixture(markdown: "# Version", manifest: manifest) { rootURL in
            try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        }
        Issue.record("Expected unsupported version failure")
    } catch let error as ASKPageRuntimeError {
        guard case .unsupportedManifestVersion(let version) = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
        #expect(version == 99)
    }
}

@Test("File-system runtime loader rejects missing manifests")
func fileSystemRuntimeLoaderRejectsMissingManifest() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    do {
        _ = try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        Issue.record("Expected missing manifest failure")
    } catch let error as ASKPageRuntimeError {
        guard case .missingManifest(let path) = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
        #expect(path.hasSuffix(ASKPageRuntimeManifest.defaultFilename))
    }
}

@Test("File-system runtime loader resolves filesystem paths when the package root contains spaces")
func fileSystemRuntimeLoaderUsesDecodedFileSystemPathsForRootsWithSpaces() async throws {
    let document = ASKPageDocument(
        id: .init("doc-spaces"),
        title: "Spaces",
        source: .init(kind: .package),
        sections: [],
        blocks: []
    )
    let manifest = ASKPageRuntimeManifest(
        documentJSONPath: "document.json",
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-spaces"),
            sourceID: .init("src-spaces"),
            title: "Spaces"
        )
    )

    let package = try await withRuntimeFixture(
        document: document,
        markdown: "# Spaces\n\nFilesystem path semantics.",
        manifest: manifest,
        rootURL: makeTemporaryDirectory(suffix: " Application Support")
    ) { rootURL in
        let manifestURL = rootURL
            .appendingPathComponent(ASKPageRuntimeManifest.defaultFilename, isDirectory: false)
            .standardizedFileURL
        let decodedPath = manifestURL.path(percentEncoded: false)
        let encodedPath = manifestURL.path()

        #expect(decodedPath.contains("Application Support"))
        #expect(encodedPath.contains("Application%20Support"))
        #expect(FileManager.default.fileExists(atPath: decodedPath))
        #expect(!FileManager.default.fileExists(atPath: encodedPath))

        return try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
    }

    #expect(package.document.id == .init("doc-spaces"))
    #expect(package.selection.selectedKind == .markdown)
}

@Test("File-system runtime loader rejects missing markdown when markdown is the canonical document source")
func fileSystemRuntimeLoaderRejectsMissingMarkdownArtifact() async throws {
    let manifest = ASKPageRuntimeManifest(
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-missing-markdown"),
            sourceID: .init("src-missing-markdown")
        )
    )

    do {
        _ = try await withRuntimeFixture(manifest: manifest) { rootURL in
            try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        }
        Issue.record("Expected missing markdown artifact failure")
    } catch let error as ASKPageRuntimeError {
        guard case .fileNotFound(let path) = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
        #expect(path == "document.md")
    }
}

@Test("File-system runtime loader rejects malformed canonical document JSON")
func fileSystemRuntimeLoaderRejectsMalformedCanonicalDocumentJSON() async throws {
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json", scenePath: "scene.json")
    let scene = ASKCanvasPage(id: .init("scene-malformed-doc"), elements: [])

    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeJSON(manifest, to: rootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename))
    try writeRawData(Data("not-json".utf8), to: rootURL.appendingPathComponent("document.json"))
    try writeJSON(scene, to: rootURL.appendingPathComponent("scene.json"))

    do {
        _ = try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        Issue.record("Expected malformed document failure")
    } catch let error as ASKPageRuntimeError {
        guard case .failedToDecodeDocument(let path) = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
        #expect(path == "document.json")
    }
}

@Test("File-system runtime loader rejects malformed scene JSON")
func fileSystemRuntimeLoaderRejectsMalformedSceneJSON() async throws {
    let document = ASKPageDocument(
        id: .init("doc-malformed-scene"),
        title: "Malformed Scene",
        source: .init(kind: .package),
        sections: [],
        blocks: []
    )
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json", scenePath: "scene.json")

    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeJSON(manifest, to: rootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename))
    try writeJSON(document, to: rootURL.appendingPathComponent("document.json"))
    try writeRawData(Data("not-json".utf8), to: rootURL.appendingPathComponent("scene.json"))

    do {
        _ = try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
        Issue.record("Expected malformed scene failure")
    } catch let error as ASKPageRuntimeError {
        guard case .failedToDecodeScene(let path) = error else {
            Issue.record("Unexpected runtime error: \(error)")
            return
        }
        #expect(path == "scene.json")
    }
}

@Test("File-system runtime loader allows an in-root artifact symlink")
func fileSystemRuntimeLoaderAllowsInRootArtifactSymlink() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let manifest = ASKPageRuntimeManifest(
        markdown: .init(path: "document.md", documentID: .init("doc-link"), sourceID: .init("src-link"))
    )
    try writeJSON(manifest, to: rootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename))
    try "# Linked\n\nIn root.".write(to: rootURL.appendingPathComponent("real.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: rootURL.appendingPathComponent("document.md"),
        withDestinationURL: rootURL.appendingPathComponent("real.md")
    )

    let package = try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
    #expect(package.document.title == "Linked")
    guard case .markdown(let markdown) = package.selectedArtifact else {
        Issue.record("Expected markdown payload")
        return
    }
    #expect(markdown == "# Linked\n\nIn root.")
}

@Test("File-system runtime loader rejects external and dangling artifact symlinks")
func fileSystemRuntimeLoaderRejectsExternalAndDanglingSymlinks() async throws {
    for dangling in [false, true] {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let outsideURL = rootURL.deletingLastPathComponent().appendingPathComponent("runtime-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)

        let manifest = ASKPageRuntimeManifest(
            markdown: .init(path: "document.md", documentID: .init("doc-external-link"), sourceID: .init("src-external-link"))
        )
        try writeJSON(manifest, to: rootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename))
        let outsideDocument = outsideURL.appendingPathComponent("outside.md")
        if !dangling {
            try "# Outside".write(to: outsideDocument, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("document.md"),
            withDestinationURL: outsideDocument
        )

        do {
            _ = try await ASKPageFileSystemRuntimeLoader().loadPackage(from: .init(rootURL: rootURL))
            Issue.record("Expected external symlink rejection")
        } catch let error as ASKPageRuntimeError {
            guard case .filePathEscapesRoot("document.md") = error else {
                Issue.record("Unexpected runtime error: \(error)")
                continue
            }
        }
    }
}

@Test("File-system runtime loader keeps reads on a descriptor-bound ancestor")
func fileSystemRuntimeLoaderKeepsReadsOnDescriptorBoundAncestor() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sceneDirectory = rootURL.appendingPathComponent("scene-dir", isDirectory: true)
    let heldDirectory = rootURL.appendingPathComponent("scene-held", isDirectory: true)
    let outsideURL = rootURL.deletingLastPathComponent().appendingPathComponent("runtime-race-outside-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    try FileManager.default.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)

    let document = ASKPageDocument(id: .init("doc-race"), title: "Race", source: .init(kind: .package), sections: [], blocks: [])
    let originalScene = ASKCanvasPage(id: .init("original-scene"), elements: [])
    let outsideScene = ASKCanvasPage(id: .init("outside-scene"), elements: [])
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json", scenePath: "scene-dir/scene.json")
    try writeJSON(manifest, to: rootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename))
    try writeJSON(document, to: rootURL.appendingPathComponent("document.json"))
    try writeJSON(originalScene, to: sceneDirectory.appendingPathComponent("scene.json"))
    try writeJSON(outsideScene, to: outsideURL.appendingPathComponent("scene.json"))

    let swapState = RuntimeSwapState()
    let loader = ASKPageFileSystemRuntimeLoader { path, _ in
        guard path == "scene-dir/scene.json", !swapState.swapped else { return }
        swapState.swapped = true
        try? FileManager.default.moveItem(at: sceneDirectory, to: heldDirectory)
        try? FileManager.default.createSymbolicLink(at: sceneDirectory, withDestinationURL: outsideURL)
    }

    let package = try await loader.loadPackage(from: .init(rootURL: rootURL))
    #expect(swapState.swapped)
    guard case .scene(let scene) = package.selectedArtifact else {
        Issue.record("Expected scene payload")
        return
    }
    #expect(scene == originalScene)
    #expect(scene != outsideScene)
}

private final class RuntimeSwapState: @unchecked Sendable {
    var swapped = false
}

private func withRuntimeFixture<T>(
    document: ASKPageDocument? = nil,
    scene: ASKCanvasPage? = nil,
    hybridTemplateHTML: String? = nil,
    fullHTML: String? = nil,
    markdown: String? = nil,
    manifest: ASKPageRuntimeManifest,
    rootURL: URL? = nil,
    body: (URL) async throws -> T
) async throws -> T {
    let rootURL = try rootURL ?? makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeJSON(manifest, to: rootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename))
    if let document {
        try writeJSON(document, to: rootURL.appendingPathComponent("document.json"))
    }
    if let scene {
        if manifest.scenePath == "../scene.json" {
            let externalURL = rootURL.deletingLastPathComponent().appendingPathComponent("scene.json")
            try writeJSON(scene, to: externalURL)
        } else {
            try writeJSON(scene, to: rootURL.appendingPathComponent("scene.json"))
        }
    }
    if let hybridTemplateHTML {
        try hybridTemplateHTML.write(to: rootURL.appendingPathComponent("hybrid-template.html"), atomically: true, encoding: .utf8)
    }
    if let fullHTML {
        try fullHTML.write(to: rootURL.appendingPathComponent("full.html"), atomically: true, encoding: .utf8)
    }
    if let markdown {
        try markdown.write(to: rootURL.appendingPathComponent("document.md"), atomically: true, encoding: .utf8)
    }

    return try await body(rootURL)
}

private func makeTemporaryDirectory(suffix: String = "") throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
}

private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
}

private func writeRawData(_ data: Data, to url: URL) throws {
    try data.write(to: url)
}
