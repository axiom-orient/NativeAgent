import Foundation

public protocol SourceArtifactBuilding: Sendable {
    func buildArtifact(from url: URL, options: ASKPageIndexOptions) async throws -> SourceIndexArtifact
}

enum SourceArtifactBuildPolicies {
    private static let requiredOptionOverrides = ASKPageIndexOptionOverrides(
        ifAddNodeID: .yes,
        ifAddNodeSummary: .yes,
        ifAddDocDescription: .yes,
        ifAddNodeText: .yes
    )

    static func canonicalOptions(from options: ASKPageIndexOptions) -> ASKPageIndexOptions {
        var canonical = options.merged(with: requiredOptionOverrides)
        canonical.ifThinning = false
        canonical.minTokenThreshold = nil
        canonical.summaryTokenThreshold = 200
        return canonical
    }
}

public struct MarkdownSourceArtifactBuilder: SourceArtifactBuilding, Sendable {
    private let indexer: any MarkdownIndexing

    public init(indexer: any MarkdownIndexing = MarkdownIndexer()) {
        self.indexer = indexer
    }

    public func buildArtifact(from url: URL, options: ASKPageIndexOptions) async throws -> SourceIndexArtifact {
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw ASKPageIndexError.unsupportedFileFormat(url.path)
        }
        let data = try Data(contentsOf: url)
        let version = try SourceIdentityFactory.makeVersion(data: data, forFileAt: url)
        let sourceID = SourceIdentityFactory.makeID(forFileAt: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ASKPageIndexError.decodeFailure("Markdown source is not valid UTF-8: \(url.path)")
        }
        // Range coordinates must use the same logical newlines as the outline.
        // The SourceVersion above remains the checksum of the untouched raw bytes.
        let lines = MarkdownParser.normalizeLineEndings(content)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let frontmatter = ASKEvidenceMetadataExtractor.parseFrontmatter(markdown: content)
        let indexed = try await indexer.index(
            markdownContent: content,
            sourceName: url.deletingPathExtension().lastPathComponent,
            sourcePath: url.path,
            options: SourceArtifactBuildPolicies.canonicalOptions(from: options)
        )
        let nodes = try SourceArtifactNodeMapper.mapMarkdown(
            nodes: indexed.structure ?? [],
            totalExtents: lines.count,
            sourceID: sourceID
        )
        return SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .md,
                title: indexed.docName,
                description: indexed.docDescription,
                coordinateSpace: .line,
                extentCount: lines.count,
                rootNodes: nodes
            ),
            excerpts: lines.enumerated().map { SourceExcerpt(index: $0.offset + 1, content: $0.element) },
            version: version,
            sourcePath: url.path,
            frontmatter: frontmatter,
            evidenceMetadata: ASKEvidenceMetadataExtractor.metadata(
                sourceID: sourceID,
                sourcePath: url.path,
                documentTitle: indexed.docName,
                frontmatter: frontmatter
            ),
            extractionQuality: .digitalText
        )
    }
}

public struct PDFSourceArtifactBuilder: SourceArtifactBuilding, Sendable {
    private let indexer: any PDFIndexing

    public init(indexer: any PDFIndexing = SwiftPDFIndexer()) {
        self.indexer = indexer
    }

    public func buildArtifact(from url: URL, options: ASKPageIndexOptions) async throws -> SourceIndexArtifact {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw ASKPageIndexError.unsupportedFileFormat(url.path)
        }
        let version = try SourceIdentityFactory.makeVersion(forFileAt: url)
        let sourceID = SourceIdentityFactory.makeID(forFileAt: url)
        let indexed = try await indexer.index(pdfAt: url, options: SourceArtifactBuildPolicies.canonicalOptions(from: options))
        let pageCount = indexed.pageCount ?? indexed.pages?.count ?? 0
        let pages = indexed.pages ?? []
        let nonBlankPageCount = pages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard nonBlankPageCount > 0 else {
            throw ASKPageIndexError.ocrRequired(url.path)
        }
        let extractionQuality: SourceExtractionQuality = nonBlankPageCount == pages.count ? .digitalText : .layoutUncertain
        let nodes = try SourceArtifactNodeMapper.mapDocumentNodes(
            nodes: indexed.structure ?? [],
            coordinateSpace: .page,
            sourceID: sourceID
        )
        return SourceIndexArtifact(
            document: SourceIndexDocument(
                sourceID: sourceID,
                type: .pdf,
                title: indexed.docName,
                description: indexed.docDescription,
                coordinateSpace: .page,
                extentCount: pageCount,
                rootNodes: nodes
            ),
            excerpts: pages.map { SourceExcerpt(index: $0.page, content: $0.content) },
            version: version,
            sourcePath: url.path,
            evidenceMetadata: ASKEvidenceMetadataExtractor.metadata(
                sourceID: sourceID,
                sourcePath: url.path,
                documentTitle: indexed.docName
            ),
            extractionQuality: extractionQuality
        )
    }
}

public struct DefaultSourceArtifactBuilder: SourceArtifactBuilding, Sendable {
    private let markdownBuilder: MarkdownSourceArtifactBuilder
    private let pdfBuilder: PDFSourceArtifactBuilder

    public init(markdownBuilder: MarkdownSourceArtifactBuilder = MarkdownSourceArtifactBuilder(), pdfBuilder: PDFSourceArtifactBuilder = PDFSourceArtifactBuilder()) {
        self.markdownBuilder = markdownBuilder
        self.pdfBuilder = pdfBuilder
    }

    public func buildArtifact(from url: URL, options: ASKPageIndexOptions) async throws -> SourceIndexArtifact {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return try await markdownBuilder.buildArtifact(from: url, options: options)
        case "pdf":
            return try await pdfBuilder.buildArtifact(from: url, options: options)
        default:
            throw ASKPageIndexError.unsupportedFileFormat(url.path)
        }
    }
}

enum SourceArtifactNodeMapper {
    static func mapMarkdown(nodes: [DocumentNode], totalExtents: Int, sourceID: SourceID) throws -> [SourceIndexNode] {
        try mapMarkdownSiblings(nodes, parentEnd: totalExtents, sourceID: sourceID)
    }

    static func mapDocumentNodes(nodes: [DocumentNode], coordinateSpace: SourceLocationSpace, sourceID: SourceID) throws -> [SourceIndexNode] {
        try nodes.map { node in
            guard let start = node.startIndex, let end = node.endIndex else {
                throw ASKPageIndexError.decodeFailure("Missing explicit range for document node \(node.title)")
            }
            let range = try SourceRange(space: coordinateSpace, start: start, end: end)
            return SourceIndexNode(
                nodeID: node.nodeID ?? syntheticNodeID(for: sourceID, title: node.title, start: start, end: end),
                title: node.title,
                range: range,
                summary: node.summary ?? node.prefixSummary,
                snippet: snippet(from: node.text),
                children: try mapDocumentNodes(nodes: node.nodes ?? [], coordinateSpace: coordinateSpace, sourceID: sourceID)
            )
        }
    }

    private static func mapMarkdownSiblings(_ nodes: [DocumentNode], parentEnd: Int, sourceID: SourceID) throws -> [SourceIndexNode] {
        try nodes.enumerated().map { index, node in
            guard let start = node.lineNumber else {
                throw ASKPageIndexError.decodeFailure("Missing lineNumber for markdown node \(node.title)")
            }
            let nextLine = index + 1 < nodes.count ? nodes[index + 1].lineNumber : nil
            let computedEnd = min(parentEnd, (nextLine ?? (parentEnd + 1)) - 1)
            let end = max(start, computedEnd)
            let range = try SourceRange(space: .line, start: start, end: end)
            let children = try mapMarkdownSiblings(node.nodes ?? [], parentEnd: end, sourceID: sourceID)
            return SourceIndexNode(
                nodeID: node.nodeID ?? syntheticNodeID(for: sourceID, title: node.title, start: start, end: end),
                title: node.title,
                range: range,
                summary: node.summary ?? node.prefixSummary,
                snippet: snippet(from: node.text),
                children: children
            )
        }
    }

    private static func snippet(from text: String?, maxWords: Int = 40) -> String? {
        guard let text else { return nil }
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized.split(separator: " ").prefix(maxWords).joined(separator: " ")
    }

    private static func syntheticNodeID(for sourceID: SourceID, title: String, start: Int, end: Int) -> String {
        let basis = "\(sourceID.rawValue)|\(title)|\(start)|\(end)"
        return String(StableDigest.sha256Hex(Data(basis.utf8)).prefix(12))
    }
}
