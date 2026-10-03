import Foundation
import KnowledgeRuntime
import DocumentCore
import DocumentRuntime
import PageIndex

public struct ASKPresentationSelection: Sendable, Hashable {
    public let projectionSlug: String
    public let bundleName: String
    public let bundleRootURL: URL

    public init(projectionSlug: String, bundleName: String, bundleRootURL: URL) {
        self.projectionSlug = projectionSlug
        self.bundleName = bundleName
        self.bundleRootURL = bundleRootURL
    }
}

public struct ASKPresentationBuilder: Sendable {
    public let compiler: ASKPageMarkdownCompiler

    public init(compiler: ASKPageMarkdownCompiler = ASKPageMarkdownCompiler()) {
        self.compiler = compiler
    }

    @discardableResult
    public func materializeProjection(
        slug: String,
        reader: any ASKKnowledgeReader,
        workspace: ASKKnowledgeWorkspacePaths,
        fileManager: FileManager = .default
    ) throws -> ASKProjectionPresentationPackage {
        guard let projection = try reader.projectionDocument(slug: slug) else {
            throw ASKKnowledgeWorkspaceError.projectionNotFound(slug)
        }

        let selection = ASKPresentationSelection(
            projectionSlug: projection.slug,
            bundleName: projection.slug,
            bundleRootURL: try workspace.presentationBundleRoot(named: projection.slug)
        )
        try fileManager.createDirectory(at: selection.bundleRootURL, withIntermediateDirectories: true)

        let markdownRelativePath = "document.md"
        let documentRelativePath = "document.json"
        let documentID = pageDocumentID(forProjectionSlug: projection.slug)
        let sourceID = pageSourceID(forProjectionSlug: projection.slug)
        let document = compiler.compile(
            markdown: projection.bodyMD,
            documentID: documentID,
            sourceID: sourceID,
            title: projection.title,
            authoritativeMarkdownPath: markdownRelativePath
        )
        let runtimeManifest = ASKPageRuntimeManifest(
            documentJSONPath: documentRelativePath,
            markdown: ASKPageRuntimeMarkdownArtifact(
                path: markdownRelativePath,
                documentID: documentID,
                sourceID: sourceID,
                title: projection.title,
                authoritativeMarkdownPath: markdownRelativePath
            )
        )

        let bindingStore = ASKPageIndexSourceBindingStore(rootURL: workspace.pageIndexRoot)
        let bindingResolution = try bindingStore.resolveBindings(forASKSourceIDs: projection.metadata.sourceIDs)
        let presentationManifest = ASKProjectionPresentationManifest(
            projectionSlug: projection.slug,
            projectionTitle: projection.title,
            bundleName: selection.bundleName,
            generatedFromHash: projection.generatedFromHash,
            generatedAt: projection.generatedAt,
            sourceIDs: projection.metadata.sourceIDs,
            pageIndexBindings: bindingResolution.bindings,
            unboundSourceIDs: bindingResolution.unboundASKSourceIDs,
            documentID: documentID,
            sourceID: sourceID,
            runtimeManifestPath: ASKPageRuntimeManifest.defaultFilename,
            documentJSONPath: documentRelativePath,
            markdownPath: markdownRelativePath
        )

        try writeUTF8(
            projection.bodyMD,
            to: selection.bundleRootURL.appendingPathComponent(markdownRelativePath, isDirectory: false),
            errorCase: .failedToWritePresentationMarkdown(projection.slug)
        )
        try writeJSON(
            document,
            to: selection.bundleRootURL.appendingPathComponent(documentRelativePath, isDirectory: false),
            errorCase: .failedToWritePresentationDocument(projection.slug)
        )
        try writeJSON(
            runtimeManifest,
            to: selection.bundleRootURL.appendingPathComponent(ASKPageRuntimeManifest.defaultFilename, isDirectory: false),
            errorCase: .failedToWritePresentationManifest(projection.slug)
        )
        try writeJSON(
            presentationManifest,
            to: selection.bundleRootURL.appendingPathComponent(ASKProjectionPresentationManifest.defaultFilename, isDirectory: false),
            errorCase: .failedToWritePresentationManifest(projection.slug)
        )

        return ASKProjectionPresentationPackage(
            projection: projection,
            manifest: presentationManifest,
            bundleRootURL: selection.bundleRootURL
        )
    }

    public func pageDocumentID(forProjectionSlug slug: String) -> ASKPageDocumentID {
        ASKPageDocumentID("projection/\(slug)")
    }

    public func pageSourceID(forProjectionSlug slug: String) -> ASKPageSourceID {
        ASKPageSourceID("projection/\(slug)")
    }

    private func writeUTF8(_ value: String, to url: URL, errorCase: ASKKnowledgeWorkspaceError) throws {
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw errorCase
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL, errorCase: ASKKnowledgeWorkspaceError) throws {
        let encoder = JSONEncoderFactory.makeEncoder(prettyPrinted: true)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            throw errorCase
        }
    }
}
