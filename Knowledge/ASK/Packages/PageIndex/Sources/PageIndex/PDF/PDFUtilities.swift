import Foundation

public struct FlatTOCEntry: Codable, Equatable, Sendable {
    public var structure: String?
    public var title: String
    public var page: Int?
    public var physicalIndex: Int?
    public var appearStart: ToggleFlag?
    public var startIndex: Int?
    public var endIndex: Int?

    public init(structure: String? = nil, title: String, page: Int? = nil, physicalIndex: Int? = nil, appearStart: ToggleFlag? = nil, startIndex: Int? = nil, endIndex: Int? = nil) {
        self.structure = structure
        self.title = title
        self.page = page
        self.physicalIndex = physicalIndex
        self.appearStart = appearStart
        self.startIndex = startIndex
        self.endIndex = endIndex
    }

    enum CodingKeys: String, CodingKey {
        case structure
        case title
        case page
        case physicalIndex = "physical_index"
        case appearStart = "appear_start"
        case startIndex = "start_index"
        case endIndex = "end_index"
    }
}

public struct MatchingPagePair: Equatable, Sendable {
    public var title: String
    public var page: Int?
    public var physicalIndex: Int?

    public init(title: String, page: Int?, physicalIndex: Int?) {
        self.title = title
        self.page = page
        self.physicalIndex = physicalIndex
    }
}

public protocol PDFPageExtracting: Sendable {
    func pageCount(for url: URL) throws -> Int
    func extractPages(from url: URL) throws -> [DocumentPage]
}

public protocol PDFIndexing: Sendable {
    func index(pdfAt url: URL, options: ASKPageIndexOptions) async throws -> IndexedDocument
}

public struct UnavailablePDFIndexer: PDFIndexing, Sendable {
    public init() {}
    public func index(pdfAt url: URL, options: ASKPageIndexOptions) async throws -> IndexedDocument {
        throw ASKPageIndexError.unsupportedOperation("PDF indexing is not available without an injected PDFIndexing engine")
    }
}

public struct UnsupportedPDFPageExtractor: PDFPageExtracting, Sendable {
    public init() {}

    public func pageCount(for url: URL) throws -> Int {
        throw ASKPageIndexError.unsupportedOperation("PDF page extraction requires PDFKit on Apple platforms")
    }

    public func extractPages(from url: URL) throws -> [DocumentPage] {
        throw ASKPageIndexError.unsupportedOperation("PDF page extraction requires PDFKit on Apple platforms")
    }
}

public struct SnapshotPDFPageExtractor: PDFPageExtracting, Sendable {
    private let loader: any PDFDocumentSnapshotLoading

    public init(loader: (any PDFDocumentSnapshotLoading)? = nil) {
        self.loader = loader ?? DefaultPDFDocumentSnapshotLoader.make()
    }

    public func pageCount(for url: URL) throws -> Int {
        try loader.loadSnapshot(from: url).pageTexts.count
    }

    public func extractPages(from url: URL) throws -> [DocumentPage] {
        let snapshot = try loader.loadSnapshot(from: url)
        return snapshot.pageTexts.enumerated().map { DocumentPage(page: $0.offset + 1, content: $0.element) }
    }
}

public enum PDFPhysicalIndexUtilities {
    public static func findTOCPages(startPageIndex: Int, detectorResults: [String], tocCheckPageNum: Int) -> [Int] {
        guard startPageIndex >= 0 else { return [] }
        var lastPageIsYes = false
        var tocPageList: [Int] = []
        var index = startPageIndex
        while index < detectorResults.count {
            if index >= tocCheckPageNum && !lastPageIsYes { break }
            let detectedResult = detectorResults[index]
            if detectedResult == "yes" {
                tocPageList.append(index)
                lastPageIsYes = true
            } else if detectedResult == "no" && lastPageIsYes {
                break
            }
            index += 1
        }
        return tocPageList
    }

    public static func extractMatchingPagePairs(tocPage: [FlatTOCEntry], tocPhysicalIndex: [FlatTOCEntry], startPageIndex: Int) -> [MatchingPagePair] {
        var pairs: [MatchingPagePair] = []
        for physicalItem in tocPhysicalIndex {
            for pageItem in tocPage where physicalItem.title == pageItem.title {
                if let physicalIndex = physicalItem.physicalIndex, physicalIndex >= startPageIndex {
                    pairs.append(MatchingPagePair(title: physicalItem.title, page: pageItem.page, physicalIndex: physicalIndex))
                }
            }
        }
        return pairs
    }

    public static func calculatePageOffset(_ pairs: [MatchingPagePair]) -> Int? {
        var differences: [Int] = []
        for pair in pairs {
            guard let physicalIndex = pair.physicalIndex, let pageNumber = pair.page else { continue }
            let (difference, overflow) = physicalIndex.subtractingReportingOverflow(pageNumber)
            guard !overflow else { continue }
            differences.append(difference)
        }
        guard !differences.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for diff in differences {
            let count = counts[diff, default: 0]
            counts[diff] = count == Int.max ? Int.max : count + 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    public static func addPageOffsetToTOCJSON(_ data: [FlatTOCEntry], offset: Int) -> [FlatTOCEntry] {
        data.map {
            var copy = $0
            if let page = copy.page {
                let (physicalIndex, overflow) = page.addingReportingOverflow(offset)
                copy.physicalIndex = overflow ? nil : physicalIndex
                copy.page = nil
            }
            return copy
        }
    }

    public static func pageListToGroupText(pageContents: [String], tokenLengths: [Int], maxTokens: Int = 20_000, overlapPage: Int = 1) -> [String] {
        guard pageContents.count == tokenLengths.count, maxTokens > 0, overlapPage >= 0,
              tokenLengths.allSatisfy({ $0 >= 0 }) else { return [] }

        var tokenCount = 0
        for tokenLength in tokenLengths {
            let (nextCount, overflow) = tokenCount.addingReportingOverflow(tokenLength)
            guard !overflow else { return [] }
            tokenCount = nextCount
        }
        if tokenCount <= maxTokens { return [pageContents.joined()] }
        var subsets: [String] = []
        var currentSubset: [String] = []
        var currentTokenCount = 0
        let expectedPartsNum = tokenCount / maxTokens + (tokenCount % maxTokens == 0 ? 0 : 1)
        let averageDouble = ((Double(tokenCount) / Double(expectedPartsNum)) + Double(maxTokens)) / 2.0
        let averageTokensPerPart: Int
        if !averageDouble.isFinite || averageDouble >= Double(Int.max) {
            averageTokensPerPart = Int.max
        } else {
            averageTokensPerPart = max(1, Int(ceil(averageDouble)))
        }
        for (index, pair) in zip(pageContents.indices, zip(pageContents, tokenLengths)) {
            let (pageContent, pageTokens) = pair
            let (nextTokenCount, tokenOverflow) = currentTokenCount.addingReportingOverflow(pageTokens)
            if (tokenOverflow || nextTokenCount > averageTokensPerPart) && !currentSubset.isEmpty {
                subsets.append(currentSubset.joined())
                let overlapStart = index > overlapPage ? index - overlapPage : 0
                currentSubset = Array(pageContents[overlapStart..<index])
                currentTokenCount = 0
                for overlapTokens in tokenLengths[overlapStart..<index] {
                    let (nextCount, overflow) = currentTokenCount.addingReportingOverflow(overlapTokens)
                    guard !overflow else { return [] }
                    currentTokenCount = nextCount
                }
            }
            currentSubset.append(pageContent)
            let (updatedTokenCount, overflow) = currentTokenCount.addingReportingOverflow(pageTokens)
            guard !overflow else { return [] }
            currentTokenCount = updatedTokenCount
        }
        if !currentSubset.isEmpty { subsets.append(currentSubset.joined()) }
        return subsets
    }

    public static func addPrefaceIfNeeded(_ data: [FlatTOCEntry]) -> [FlatTOCEntry] {
        guard !data.isEmpty else { return data }
        if let firstIndex = data[0].physicalIndex, firstIndex > 1 {
            var result = data
            result.insert(FlatTOCEntry(structure: "0", title: "Preface", physicalIndex: 1), at: 0)
            return result
        }
        return data
    }

    public static func validateAndTruncatePhysicalIndices(_ tocWithPageNumber: [FlatTOCEntry], pageListLength: Int, startIndex: Int = 1) -> [FlatTOCEntry] {
        guard pageListLength >= 0 else {
            return tocWithPageNumber.map { entry in
                var copy = entry
                copy.physicalIndex = nil
                return copy
            }
        }
        let (startOffset, startUnderflow) = startIndex.subtractingReportingOverflow(1)
        let (maxAllowedPage, overflow) = pageListLength.addingReportingOverflow(startOffset)
        guard !startUnderflow, !overflow else {
            return tocWithPageNumber.map { entry in
                var copy = entry
                copy.physicalIndex = nil
                return copy
            }
        }
        return tocWithPageNumber.map {
            var copy = $0
            if let originalIndex = copy.physicalIndex, originalIndex > maxAllowedPage {
                copy.physicalIndex = nil
            }
            return copy
        }
    }

    public static func postProcessing(structure: [FlatTOCEntry], endPhysicalIndex: Int) -> [DocumentNode] {
        var mutable = structure
        for index in mutable.indices {
            mutable[index].startIndex = mutable[index].physicalIndex
            if index < mutable.count - 1 {
                let next = mutable[index + 1]
                if next.appearStart == .yes, let nextPhysicalIndex = next.physicalIndex {
                    let (endIndex, overflow) = nextPhysicalIndex.subtractingReportingOverflow(1)
                    mutable[index].endIndex = overflow ? nil : endIndex
                } else {
                    mutable[index].endIndex = next.physicalIndex
                }
            } else {
                mutable[index].endIndex = endPhysicalIndex
            }
        }
        let tree = listToTree(mutable)
        if !tree.isEmpty { return tree }
        return mutable.map { DocumentNode(title: $0.title, startIndex: $0.startIndex, endIndex: $0.endIndex, nodes: nil) }
    }

    static func listToTree(_ data: [FlatTOCEntry]) -> [DocumentNode] {
        func parentStructure(for structure: String) -> String? {
            let parts = structure.split(separator: ".")
            guard parts.count > 1 else { return nil }
            return parts.dropLast().joined(separator: ".")
        }
        var nodesByStructure: [String: DocumentNode] = [:]
        var rootStructures: [String] = []
        var childrenByParent: [String: [String]] = [:]
        for item in data {
            guard let structure = item.structure else { continue }
            nodesByStructure[structure] = DocumentNode(title: item.title, startIndex: item.startIndex, endIndex: item.endIndex, nodes: nil)
            let parent = parentStructure(for: structure)
            if let parent, nodesByStructure[parent] != nil {
                childrenByParent[parent, default: []].append(structure)
            } else {
                rootStructures.append(structure)
            }
        }
        func buildNode(for structure: String) -> DocumentNode? {
            guard var node = nodesByStructure[structure] else { return nil }
            let childStructures = childrenByParent[structure] ?? []
            let children = childStructures.compactMap(buildNode(for:))
            node.nodes = children.isEmpty ? nil : children
            return node
        }
        return rootStructures.compactMap(buildNode(for:))
    }
}
