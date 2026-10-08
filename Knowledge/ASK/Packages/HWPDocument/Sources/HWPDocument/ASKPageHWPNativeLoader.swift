import Foundation
import DocumentCore
import DocumentRuntime

public struct ASKPageHWPNativeParser: Sendable {
    private static let fileReadChunkByteCount = 64 * 1_024

    public let limits: ASKHWPParserLimits

    public init(limits: ASKHWPParserLimits = .default) {
        self.limits = limits
    }

    public func parse(data: Data, fileURL: URL? = nil, format explicitFormat: ASKHWPDocumentFormat? = nil) throws -> ASKHWPDocument {
        guard !data.isEmpty else { throw ASKHWPError.emptyInput }
        try limits.validateInputSize(data.count)
        let format = explicitFormat ?? ASKHWPDocumentFormat.detect(data: data, fileURL: fileURL)
        guard let format else {
            throw ASKHWPError.unsupportedFormat("Unable to detect HWP/HWPX format from extension or signature.")
        }
        switch format {
        case .hwpx:
            return try ASKHWPXParser(limits: limits).parse(data: data)
        case .hwp:
            return try ASKHWPBinaryParser(limits: limits).parse(data: data)
        }
    }

    public func parse(fileURL: URL, format explicitFormat: ASKHWPDocumentFormat? = nil) throws -> ASKHWPDocument {
        do {
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            let didStartSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didStartSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            #endif
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize {
                try limits.validateInputSize(fileSize)
            }
            let data = try readBoundedFile(fileURL)
            return try parse(data: data, fileURL: fileURL, format: explicitFormat)
        } catch let error as ASKHWPError {
            throw error
        } catch {
            throw ASKHWPError.fileReadFailed(fileURL.path)
        }
    }

    private func readBoundedFile(_ fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        var operation: Result<Data, any Error>

        do {
            var data = Data()
            data.reserveCapacity(min(limits.maximumInputByteCount, Self.fileReadChunkByteCount))

            while true {
                let remaining = limits.maximumInputByteCount - data.count
                let requestCount = remaining == 0
                    ? 1
                    : min(remaining, Self.fileReadChunkByteCount)
                let chunk = try handle.read(upToCount: requestCount) ?? Data()
                if chunk.isEmpty {
                    break
                }
                guard chunk.count <= remaining else {
                    throw ASKHWPError.unsupportedFeature("HWP/HWPX input exceeds its configured byte limit.")
                }
                data.append(chunk)
                if data.count == limits.maximumInputByteCount {
                    // The one-byte probe above detects growth after the initial stat
                    // check without allocating the entire oversized file.
                    continue
                }
            }
            operation = .success(data)
        } catch {
            operation = .failure(error)
        }

        let cleanupError: (any Error)?
        do {
            try handle.close()
            cleanupError = nil
        } catch {
            cleanupError = error
        }

        if let cleanupError {
            if case .failure(let primary) = operation {
                throw ASKHWPError.fileReadFailed(
                    "\(fileURL.path): \(primary); file descriptor cleanup failed: \(cleanupError)"
                )
            }
            throw ASKHWPError.fileReadFailed(
                "\(fileURL.path): file descriptor cleanup failed: \(cleanupError)"
            )
        }
        return try operation.get()
    }
}

public struct ASKPageHWPNativeCompiler: Sendable {
    public let parser: ASKPageHWPNativeParser

    public init(parser: ASKPageHWPNativeParser = .init()) {
        self.parser = parser
    }

    public func compile(
        data: Data,
        fileURL: URL? = nil,
        documentID: ASKPageDocumentID? = nil,
        sourceID: ASKPageSourceID? = nil,
        title: String? = nil,
        format explicitFormat: ASKHWPDocumentFormat? = nil
    ) throws -> ASKPageDocument {
        let hwpDocument = try parser.parse(data: data, fileURL: fileURL, format: explicitFormat)
        return makeASKPageDocument(
            from: hwpDocument,
            fileURL: fileURL,
            documentID: documentID,
            sourceID: sourceID,
            title: title
        )
    }

    public func compile(
        fileURL: URL,
        documentID: ASKPageDocumentID? = nil,
        sourceID: ASKPageSourceID? = nil,
        title: String? = nil,
        format explicitFormat: ASKHWPDocumentFormat? = nil
    ) throws -> ASKPageDocument {
        let hwpDocument = try parser.parse(fileURL: fileURL, format: explicitFormat)
        return makeASKPageDocument(
            from: hwpDocument,
            fileURL: fileURL,
            documentID: documentID,
            sourceID: sourceID,
            title: title
        )
    }

    public func makeASKPageDocument(
        from hwpDocument: ASKHWPDocument,
        fileURL: URL? = nil,
        documentID: ASKPageDocumentID? = nil,
        sourceID explicitSourceID: ASKPageSourceID? = nil,
        title explicitTitle: String? = nil
    ) -> ASKPageDocument {
        let resolvedDocumentID = documentID ?? ASKPageDocumentID(Self.stableID(prefix: "hwp-document", fileURL: fileURL, fallback: hwpDocument.title))
        let sourceID = explicitSourceID ?? ASKPageSourceID(Self.stableID(prefix: "hwp-source", fileURL: fileURL, fallback: hwpDocument.format.rawValue))
        let resolvedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? hwpDocument.title

        var sections: [ASKPageSection] = []
        var blocks: [ASKPageBlock] = []
        var sourceOffset = 0

        for nativeSection in hwpDocument.sections {
            let sectionID = ASKPageSectionID("hwp-section-\(nativeSection.index + 1)")
            let sectionTitle = nativeSection.title ?? (nativeSection.index == 0 ? resolvedTitle : "Section \(nativeSection.index + 1)")
            sections.append(.init(
                id: sectionID,
                title: sectionTitle,
                level: 1,
                sourceAnchor: .init(sourceID: sourceID, fragment: nativeSection.sourcePath)
            ))

            func appendParagraph(_ paragraph: ASKHWPParagraph, syntheticText: String? = nil) {
                let text = syntheticText ?? paragraph.plainText
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let start = sourceOffset
                let end = start + text.count
                let range = ASKPageSourceRange(start: start, end: end)
                let anchor = ASKPageSourceAnchor(sourceID: sourceID, fragment: paragraph.sourcePath, range: range)
                let runs: [ASKPageInlineRun]
                if let syntheticText {
                    runs = [ASKPageInlineRun(text: syntheticText, sourceAnchor: anchor)]
                } else {
                    runs = paragraph.runs.map { run -> ASKPageInlineRun in
                        var emphasis: ASKPageInlineEmphasis = []
                        if run.attributes.isBold { emphasis.insert(.bold) }
                        if run.attributes.isItalic { emphasis.insert(.italic) }
                        return ASKPageInlineRun(
                            text: run.text,
                            emphasis: emphasis,
                            sourceAnchor: ASKPageSourceAnchor(sourceID: sourceID, fragment: paragraph.sourcePath, range: range)
                        )
                    }
                }
                blocks.append(.init(
                    id: ASKPageBlockID("hwp-paragraph-\(blocks.count + 1)"),
                    kind: .paragraph(.init(runs: runs, style: .body)),
                    sectionID: sectionID,
                    sourceAnchor: anchor
                ))
                sourceOffset = end + 1
            }

            func appendSyntheticParagraph(_ text: String, fragment: String?) {
                let paragraph = ASKHWPParagraph(index: blocks.count, runs: [.init(text: text)], sourcePath: fragment)
                appendParagraph(paragraph)
            }

            for block in nativeSection.contentBlocks {
                switch block {
                case .paragraph(let paragraph):
                    appendParagraph(paragraph)
                case .table(let table):
                    appendTable(table)
                case .image(let image):
                    if let altText = image.altText?.trimmingCharacters(in: .whitespacesAndNewlines), !altText.isEmpty {
                        appendSyntheticParagraph(altText, fragment: image.sourcePath)
                    }
                case .drawObject(let object):
                    if let text = (object.text ?? object.referenceID)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        appendSyntheticParagraph(text, fragment: object.sourcePath)
                    }
                }
            }

            func appendTable(_ table: ASKHWPTable) {
                for row in table.rows {
                    for cell in row.cells {
                        for paragraph in cell.paragraphs {
                            appendParagraph(paragraph)
                        }
                        for nestedTable in cell.nestedTables {
                            appendTable(nestedTable)
                        }
                    }
                }
            }
        }

        return ASKPageDocument(
            id: resolvedDocumentID,
            title: resolvedTitle,
            source: .init(
                kind: hwpDocument.format == .hwpx ? .hwpx : .hwp,
                revision: hwpDocument.metadata["version"],
                authoritativeMarkdownPath: nil
            ),
            sections: sections,
            blocks: blocks
        )
    }

    private static func stableID(prefix: String, fileURL: URL?, fallback: String) -> String {
        let base = fileURL?.lastPathComponent ?? fallback
        let normalized = base
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                    return Character(scalar)
                }
                return "-"
            }
        let collapsed = String(normalized).split(separator: "-").joined(separator: "-")
        return "\(prefix)-\(collapsed.isEmpty ? "untitled" : collapsed)"
    }
}

public struct ASKPageHWPNativeDocumentLoader: ASKPageDocumentLoader, Sendable {
    public let compiler: ASKPageHWPNativeCompiler
    public let fileName: String

    public init(fileName: String, compiler: ASKPageHWPNativeCompiler = .init()) {
        self.fileName = fileName
        self.compiler = compiler
    }

    public func loadDocument(from location: ASKPageDocumentLocation) async throws -> ASKPageDocument {
        guard !fileName.hasPrefix("/") else {
            throw ASKHWPError.fileReadFailed(fileName)
        }
        let fileURL = location.rootURL.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        let canonicalRoot = location.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        let filePath = canonicalFile.path
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        guard filePath == rootPath || filePath.hasPrefix(rootPrefix) else {
            throw ASKHWPError.fileReadFailed(fileName)
        }
        return try compiler.compile(fileURL: fileURL)
    }
}
