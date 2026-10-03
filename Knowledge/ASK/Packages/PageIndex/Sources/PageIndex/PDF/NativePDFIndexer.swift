import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

public struct PDFOutlineItem: Equatable, Sendable {
    public let title: String
    public let pageIndex: Int?
    public let children: [PDFOutlineItem]

    public init(title: String, pageIndex: Int?, children: [PDFOutlineItem] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

public struct PDFDocumentSnapshot: Equatable, Sendable {
    public let title: String
    public let pageTexts: [String]
    public let outline: [PDFOutlineItem]

    public init(title: String, pageTexts: [String], outline: [PDFOutlineItem]) {
        self.title = title
        self.pageTexts = pageTexts
        self.outline = outline
    }
}

public protocol PDFDocumentSnapshotLoading: Sendable {
    func loadSnapshot(from url: URL) throws -> PDFDocumentSnapshot
}

public struct UnsupportedPDFDocumentSnapshotLoader: PDFDocumentSnapshotLoading, Sendable {
    public init() {}

    public func loadSnapshot(from url: URL) throws -> PDFDocumentSnapshot {
        throw ASKPageIndexError.unsupportedOperation("PDF loading requires PDFKit on Apple platforms")
    }
}

#if canImport(PDFKit)
public struct PDFKitDocumentSnapshotLoader: PDFDocumentSnapshotLoading, Sendable {
    public init() {}

    public func loadSnapshot(from url: URL) throws -> PDFDocumentSnapshot {
        guard let document = PDFDocument(url: url) else {
            throw ASKPageIndexError.decodeFailure("Failed to load PDF document at \(url.path)")
        }

        let pageTexts: [String] = (0 ..< document.pageCount).map { index in
            guard let page = document.page(at: index) else { return "" }
            return page.string ?? ""
        }

        let outline: [PDFOutlineItem]
        if let outlineRoot = document.outlineRoot {
            outline = extractOutlineItems(from: outlineRoot, document: document)
        } else {
            outline = []
        }

        return PDFDocumentSnapshot(
            title: url.lastPathComponent,
            pageTexts: pageTexts,
            outline: outline
        )
    }

    private func extractOutlineItems(from outline: PDFOutline, document: PDFDocument) -> [PDFOutlineItem] {
        guard outline.numberOfChildren > 0 else {
            return []
        }
        return (0 ..< outline.numberOfChildren).compactMap { childIndex in
            guard let child = outline.child(at: childIndex) else { return nil }
            let pageIndex: Int?
            if let page = child.destination?.page {
                pageIndex = document.index(for: page) + 1
            } else {
                pageIndex = nil
            }
            return PDFOutlineItem(
                title: child.label ?? "",
                pageIndex: pageIndex,
                children: extractOutlineItems(from: child, document: document)
            )
        }
    }
}
#endif

public struct SwiftPDFIndexer: PDFIndexing, Sendable {
    private let loader: any PDFDocumentSnapshotLoading
    private let tokenCounter: any TokenCounting

    public init(loader: (any PDFDocumentSnapshotLoading)? = nil, tokenCounter: any TokenCounting = WhitespaceTokenCounter()) {
        self.loader = loader ?? DefaultPDFDocumentSnapshotLoader.make()
        self.tokenCounter = tokenCounter
    }

    public func index(pdfAt url: URL, options: ASKPageIndexOptions) async throws -> IndexedDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ASKPageIndexError.fileNotFound(url.path)
        }

        let snapshot = try loader.loadSnapshot(from: url)
        guard !snapshot.pageTexts.isEmpty else {
            throw ASKPageIndexError.decodeFailure("PDF document contains no pages: \(url.path)")
        }
        guard snapshot.pageTexts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ASKPageIndexError.ocrRequired(url.path)
        }

        var structure = try buildStructure(from: snapshot, options: options)
        if options.ifAddNodeID.boolValue {
            structure = DocumentTreeUtilities.assignNodeIDs(structure, startingAt: 0)
        }
        if options.ifAddNodeSummary.boolValue {
            structure = applyDeterministicSummaries(to: structure)
        }
        let docDescription = options.ifAddDocDescription.boolValue
            ? makeDocumentDescription(title: snapshot.title, pageCount: snapshot.pageTexts.count, rootNodes: structure, firstPageText: snapshot.pageTexts[0])
            : nil
        if !options.ifAddNodeText.boolValue {
            structure = DocumentTreeUtilities.removeText(structure)
        }

        return IndexedDocument(
            type: .pdf,
            path: url.path,
            docName: snapshot.title,
            docDescription: docDescription,
            pageCount: snapshot.pageTexts.count,
            structure: structure,
            pages: snapshot.pageTexts.enumerated().map { DocumentPage(page: $0.offset + 1, content: $0.element) }
        )
    }

    private func buildStructure(from snapshot: PDFDocumentSnapshot, options: ASKPageIndexOptions) throws -> [DocumentNode] {
        let pageCount = snapshot.pageTexts.count
        let outlineItems = snapshot.outline.compactMap { normalizeOutlineItem($0, pageCount: pageCount) }
        let roots: [DocumentNode]
        if outlineItems.isEmpty {
            roots = [makeFallbackRoot(snapshot: snapshot, pageCount: pageCount)]
        } else {
            roots = buildNodes(from: outlineItems, pageTexts: snapshot.pageTexts, parentEndPage: pageCount, options: options)
        }
        return splitOversizedLeaves(in: roots, pageTexts: snapshot.pageTexts, options: options)
    }

    private func makeFallbackRoot(snapshot: PDFDocumentSnapshot, pageCount: Int) -> DocumentNode {
        DocumentNode(
            title: snapshot.title,
            startIndex: 1,
            endIndex: pageCount,
            text: joinedPageText(pageTexts: snapshot.pageTexts, start: 1, end: pageCount)
        )
    }

    private func normalizeOutlineItem(_ item: PDFOutlineItem, pageCount: Int) -> NormalizedOutlineItem? {
        let normalizedChildren = item.children.compactMap { normalizeOutlineItem($0, pageCount: pageCount) }
        let explicitStart = item.pageIndex.flatMap { (1 ... pageCount).contains($0) ? $0 : nil }
        let derivedStart = normalizedChildren.first?.startPage
        guard let startPage = explicitStart ?? derivedStart else {
            return nil
        }
        return NormalizedOutlineItem(title: item.title, startPage: startPage, children: normalizedChildren)
    }

    private func buildNodes(from items: [NormalizedOutlineItem], pageTexts: [String], parentEndPage: Int, options: ASKPageIndexOptions) -> [DocumentNode] {
        items.enumerated().map { index, item in
            let nextStartPage = index + 1 < items.count ? items[index + 1].startPage : nil
            let calculatedEnd = min(parentEndPage, (nextStartPage ?? (parentEndPage + 1)) - 1)
            let endPage = max(item.startPage, calculatedEnd)
            let children = buildNodes(from: item.children, pageTexts: pageTexts, parentEndPage: endPage, options: options)
            return DocumentNode(
                title: item.title,
                startIndex: item.startPage,
                endIndex: endPage,
                text: joinedPageText(pageTexts: pageTexts, start: item.startPage, end: endPage),
                nodes: children.isEmpty ? nil : children
            )
        }
    }

    private func splitOversizedLeaves(in nodes: [DocumentNode], pageTexts: [String], options: ASKPageIndexOptions) -> [DocumentNode] {
        nodes.map { node in
            var copy = node
            if let children = copy.nodes, !children.isEmpty {
                copy.nodes = splitOversizedLeaves(in: children, pageTexts: pageTexts, options: options)
                return copy
            }
            guard let start = copy.startIndex, let end = copy.endIndex else {
                return copy
            }
            let ranges = chunkRanges(startPage: start, endPage: end, pageTexts: pageTexts, options: options)
            guard ranges.count > 1 else {
                return copy
            }
            let children = ranges.map { range in
                DocumentNode(
                    title: chunkTitle(baseTitle: copy.title, range: range),
                    startIndex: range.lowerBound,
                    endIndex: range.upperBound,
                    text: joinedPageText(pageTexts: pageTexts, start: range.lowerBound, end: range.upperBound)
                )
            }
            copy.prefixSummary = copy.summary
            copy.summary = nil
            copy.nodes = children
            return copy
        }
    }

    private func chunkRanges(startPage: Int, endPage: Int, pageTexts: [String], options: ASKPageIndexOptions) -> [ClosedRange<Int>] {
        let maxPages = max(options.maxPageNumEachNode, 1)
        let maxTokens = max(options.maxTokenNumEachNode, 1)
        var ranges: [ClosedRange<Int>] = []
        var chunkStart: Int?
        var chunkEnd: Int?
        var chunkPageCount = 0
        var chunkTokenCount = 0

        for page in startPage ... endPage {
            let pageText = pageTexts[page - 1]
            let pageTokens = tokenCounter.countTokens(in: pageText, model: options.model)
            let wouldOverflow = chunkStart != nil && (chunkPageCount + 1 > maxPages || chunkTokenCount + pageTokens > maxTokens)
            if wouldOverflow, let currentStart = chunkStart, let currentEnd = chunkEnd {
                ranges.append(currentStart ... currentEnd)
                self.resetChunk(
                    page: page,
                    pageTokens: pageTokens,
                    chunkStart: &chunkStart,
                    chunkEnd: &chunkEnd,
                    chunkPageCount: &chunkPageCount,
                    chunkTokenCount: &chunkTokenCount
                )
            } else {
                if chunkStart == nil {
                    chunkStart = page
                }
                chunkEnd = page
                chunkPageCount += 1
                chunkTokenCount += pageTokens
            }
        }
        if let chunkStart, let chunkEnd {
            ranges.append(chunkStart ... chunkEnd)
        }
        return ranges
    }

    private func resetChunk(page: Int, pageTokens: Int, chunkStart: inout Int?, chunkEnd: inout Int?, chunkPageCount: inout Int, chunkTokenCount: inout Int) {
        chunkStart = page
        chunkEnd = page
        chunkPageCount = 1
        chunkTokenCount = pageTokens
    }

    private func applyDeterministicSummaries(to nodes: [DocumentNode]) -> [DocumentNode] {
        nodes.map { node in
            var copy = node
            if let children = copy.nodes, !children.isEmpty {
                copy.nodes = applyDeterministicSummaries(to: children)
                copy.prefixSummary = snippet(from: copy.text)
            } else {
                copy.summary = snippet(from: copy.text)
            }
            return copy
        }
    }

    private func joinedPageText(pageTexts: [String], start: Int, end: Int) -> String {
        guard start <= end else { return "" }
        let slice = pageTexts[(start - 1) ... (end - 1)]
        return slice.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snippet(from text: String?, maxWords: Int = 40) -> String? {
        guard let text else { return nil }
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let words = normalized.split(separator: " ")
        let truncated = words.prefix(maxWords)
        return truncated.joined(separator: " ")
    }

    private func makeDocumentDescription(title: String, pageCount: Int, rootNodes: [DocumentNode], firstPageText: String) -> String {
        let rootTitles = rootNodes.map(\.title).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !rootTitles.isEmpty {
            return "\(title) · \(pageCount) pages · sections: \(rootTitles.prefix(3).joined(separator: ", "))"
        }
        if let firstPageSnippet = snippet(from: firstPageText, maxWords: 24) {
            return "\(title) · \(pageCount) pages · starts: \(firstPageSnippet)"
        }
        return "\(title) · \(pageCount) pages"
    }

    private func chunkTitle(baseTitle: String, range: ClosedRange<Int>) -> String {
        if range.lowerBound == range.upperBound {
            return "\(baseTitle) [page \(range.lowerBound)]"
        }
        return "\(baseTitle) [pages \(range.lowerBound)-\(range.upperBound)]"
    }
}

private struct NormalizedOutlineItem: Equatable {
    let title: String
    let startPage: Int
    let children: [NormalizedOutlineItem]
}

enum DefaultPDFDocumentSnapshotLoader {
    static func make() -> any PDFDocumentSnapshotLoading {
        #if canImport(PDFKit)
        return PDFKitDocumentSnapshotLoader()
        #else
        return UnsupportedPDFDocumentSnapshotLoader()
        #endif
    }
}
