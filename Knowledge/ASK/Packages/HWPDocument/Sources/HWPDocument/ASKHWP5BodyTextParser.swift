import Foundation
import DocumentCore

private let askHWP5ParaHeaderTag = 66
private let askHWP5ParaTextTag = 67
private let askHWP5ParaCharShapeTag = 68
private let askHWP5CtrlHeaderTag = 71
private let askHWP5ListHeaderTag = 72
private let askHWP5PageDefTag = 73
private let askHWP5ShapeComponentTag = 76
private let askHWP5TableTag = 77
private let askHWP5ShapeOLETag = 84
private let askHWP5ShapePictureTag = 85
private let askHWP5EquationTag = 88
private let askHWP5ChartDataTag = 95

struct ASKHWP5Record: Sendable, Hashable {
    let tagID: Int
    let level: Int
    let payload: [UInt8]

    init(cursor: inout ASKByteCursor) throws {
        guard cursor.remainingCount >= 4 else {
            throw ASKHWPError.malformedDocument("Truncated HWP record header.")
        }
        let header = try cursor.readUInt32LE()
        let tagID = Int(header & 0x03FF)
        let level = Int((header >> 10) & 0x03FF)
        var size = Int((header >> 20) & 0x0FFF)
        if size == 0x0FFF {
            guard cursor.remainingCount >= 4 else {
                throw ASKHWPError.malformedDocument("Truncated HWP extended record size.")
            }
            let rawSize = try cursor.readUInt32LE()
            guard let extendedSize = Int(exactly: rawSize) else {
                throw ASKHWPError.malformedDocument("HWP record payload size exceeds host limits.")
            }
            size = extendedSize
        }
        guard size >= 0, cursor.remainingCount >= size else {
            throw ASKHWPError.malformedDocument(
                "HWP record payload escapes section stream: tag=\(tagID), size=\(size)."
            )
        }
        self.tagID = tagID
        self.level = level
        self.payload = try cursor.readBytes(count: size)
    }

    static func readAll(from data: Data) throws -> [ASKHWP5Record] {
        var cursor = ASKByteCursor(data: data)
        var records: [ASKHWP5Record] = []
        while !cursor.isAtEnd {
            records.append(try ASKHWP5Record(cursor: &cursor))
        }
        return records
    }
}

struct ASKHWP5BinaryReference: Sendable, Hashable {
    let storageID: Int
    let fileExtension: String?
}

struct ASKHWP5StyleCatalog: Sendable, Hashable {
    struct CharShape: Sendable, Hashable {
        let pointSize: Double
        let isBold: Bool
        let isItalic: Bool
    }

    struct ParaShape: Sendable, Hashable {
        let alignment: ASKHWPParagraphAlignment
        let lineHeightMultiple: Double
        let spacingBefore: Double
        let spacingAfter: Double
        let leftIndent: Double
        let rightIndent: Double
        let firstLineIndent: Double
    }

    struct Style: Sendable, Hashable {
        let paraShapeID: Int
        let charShapeID: Int
    }

    var charShapes: [Int: CharShape] = [:]
    var paraShapes: [Int: ParaShape] = [:]
    var styles: [Int: Style] = [:]
    var binaryReferences: [ASKHWP5BinaryReference] = []

    private init() {}

    init(data: Data) throws {
        let records = try ASKHWP5Record.readAll(from: data)
        for (index, record) in records.enumerated() {
            switch record.tagID {
            case 18:
                if let reference = Self.parseBinaryReference(record.payload) {
                    binaryReferences.append(reference)
                }
            case 21:
                if let shape = Self.parseCharShape(record.payload) {
                    charShapes[indexForReference(index, records: records, tagID: 21)] = shape
                }
            case 25:
                if let shape = Self.parseParaShape(record.payload) {
                    paraShapes[indexForReference(index, records: records, tagID: 25)] = shape
                }
            case 26:
                if let style = Self.parseStyle(record.payload) {
                    styles[indexForReference(index, records: records, tagID: 26)] = style
                }
            default:
                break
            }
        }
    }

    static let empty = ASKHWP5StyleCatalog()

    func paragraphStyle(paraShapeID: Int, styleID: Int) -> ASKHWPParagraphStyle {
        let style = styles[styleID]
        let selectedParaShapeID = style?.paraShapeID ?? paraShapeID
        let selected = paraShapes[selectedParaShapeID]
        return ASKHWPParagraphStyle(
            styleID: String(styleID),
            paragraphShapeID: String(selectedParaShapeID),
            alignment: selected?.alignment ?? .left,
            basePointSize: style.flatMap { charShapes[$0.charShapeID]?.pointSize } ?? 12,
            lineHeightMultiple: selected?.lineHeightMultiple ?? ASKHWPParagraphStyle.body.lineHeightMultiple,
            spacingBefore: selected?.spacingBefore ?? ASKHWPParagraphStyle.body.spacingBefore,
            spacingAfter: selected?.spacingAfter ?? ASKHWPParagraphStyle.body.spacingAfter,
            leftIndent: selected?.leftIndent ?? 0,
            rightIndent: selected?.rightIndent ?? 0,
            firstLineIndent: selected?.firstLineIndent ?? 0
        )
    }

    func charAttributes(id: Int, styleID: Int) -> ASKHWPTextAttributes {
        let resolvedID = id >= 0 ? id : (styles[styleID]?.charShapeID ?? 0)
        let shape = charShapes[resolvedID]
        return ASKHWPTextAttributes(
            styleID: String(styleID),
            charShapeID: String(resolvedID),
            pointSize: shape?.pointSize,
            isBold: shape?.isBold ?? false,
            isItalic: shape?.isItalic ?? false
        )
    }

    private static func parseBinaryReference(_ data: [UInt8]) -> ASKHWP5BinaryReference? {
        var reader = ASKHWP5ByteReader(bytes: data)
        guard let attr = reader.readUInt16() else { return nil }
        let dataType = attr & 0x000F
        guard dataType == 1 || dataType == 2, let storageID = reader.readUInt16() else {
            return nil
        }
        return ASKHWP5BinaryReference(
            storageID: Int(storageID),
            fileExtension: reader.readHWPString()?.lowercased()
        )
    }

    private static func parseCharShape(_ data: [UInt8]) -> CharShape? {
        guard data.count >= 60 else { return nil }
        let baseSize = Int32(bitPattern: readUInt32(data, at: 52) ?? 1000)
        let attr = readUInt32(data, at: 56) ?? 0
        return CharShape(
            pointSize: max(Double(baseSize) / 100.0, 1),
            isBold: attr & 0x02 != 0,
            isItalic: attr & 0x01 != 0
        )
    }

    private static func parseParaShape(_ data: [UInt8]) -> ParaShape? {
        guard data.count >= 28 else { return nil }
        let attr = readUInt32(data, at: 0) ?? 0
        let alignment: ASKHWPParagraphAlignment
        switch (attr >> 2) & 0x07 {
        case 1: alignment = .left
        case 2: alignment = .right
        case 3: alignment = .center
        case 4, 5: alignment = .justified
        default: alignment = .justified
        }
        let lineSpacing = Int32(bitPattern: readUInt32(data, at: 24) ?? 160)
        let lineHeightMultiple = max(Double(lineSpacing) / 100.0, 1)
        return ParaShape(
            alignment: alignment,
            lineHeightMultiple: lineHeightMultiple,
            spacingBefore: hwpPoint(Int32(bitPattern: readUInt32(data, at: 16) ?? 0)),
            spacingAfter: hwpPoint(Int32(bitPattern: readUInt32(data, at: 20) ?? 0)),
            leftIndent: hwpPoint(Int32(bitPattern: readUInt32(data, at: 4) ?? 0)),
            rightIndent: hwpPoint(Int32(bitPattern: readUInt32(data, at: 8) ?? 0)),
            firstLineIndent: hwpPoint(Int32(bitPattern: readUInt32(data, at: 12) ?? 0))
        )
    }

    private static func parseStyle(_ data: [UInt8]) -> Style? {
        var reader = ASKHWP5ByteReader(bytes: data)
        guard reader.readHWPString() != nil,
              reader.readHWPString() != nil,
              reader.readUInt8() != nil,
              reader.readUInt8() != nil
        else { return nil }
        _ = reader.readUInt16()
        guard let paraShapeID = reader.readUInt16(), let charShapeID = reader.readUInt16() else {
            return nil
        }
        return Style(paraShapeID: Int(paraShapeID), charShapeID: Int(charShapeID))
    }

    private func indexForReference(_ recordIndex: Int, records: [ASKHWP5Record], tagID: Int) -> Int {
        records[..<recordIndex].reduce(into: 0) { count, record in
            if record.tagID == tagID { count += 1 }
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard bytes.count >= 4, offset >= 0, offset <= bytes.count - 4 else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func hwpPoint(_ value: Int32) -> Double {
        Double(value) / 100.0
    }
}

struct ASKHWP5ParsedSection: Sendable, Hashable {
    let pageMetrics: ASKHWPPageMetrics?
    let paragraphs: [ASKHWPParagraph]
    let contentBlocks: [ASKHWPContentBlock]
}

struct ASKHWP5BodyTextParser: Sendable {
    let sourcePath: String
    let styles: ASKHWP5StyleCatalog
    let binaryPathsByStorageID: [Int: String]

    func parse(data: Data) throws -> ASKHWP5ParsedSection {
        let records = try ASKHWP5Record.readAll(from: data)
        var paragraphs: [ASKHWPParagraph] = []
        var contentBlocks: [ASKHWPContentBlock] = []
        var pageMetrics: ASKHWPPageMetrics?
        var index = 0

        while index < records.count {
            guard records[index].tagID == askHWP5ParaHeaderTag else {
                index += 1
                continue
            }
            let end = groupEnd(records: records, start: index)
            let result = parseParagraphGroup(Array(records[index..<end]))
            if let paragraph = result.paragraph {
                paragraphs.append(paragraph)
                contentBlocks.append(.paragraph(paragraph))
            }
            paragraphs.append(contentsOf: result.additionalParagraphs)
            contentBlocks.append(contentsOf: result.contentBlocks)
            if let metrics = result.pageMetrics {
                pageMetrics = metrics
            }
            index = end
        }

        return ASKHWP5ParsedSection(
            pageMetrics: pageMetrics,
            paragraphs: paragraphs,
            contentBlocks: contentBlocks
        )
    }

    private struct ParagraphResult {
        let paragraph: ASKHWPParagraph?
        let additionalParagraphs: [ASKHWPParagraph]
        let contentBlocks: [ASKHWPContentBlock]
        let pageMetrics: ASKHWPPageMetrics?
    }

    private func parseParagraphGroup(_ records: [ASKHWP5Record]) -> ParagraphResult {
        guard let header = records.first, header.tagID == askHWP5ParaHeaderTag else {
            return ParagraphResult(paragraph: nil, additionalParagraphs: [], contentBlocks: [], pageMetrics: nil)
        }

        let paraShapeID = Int(readUInt16(header.payload, at: 8) ?? 0)
        let styleID = Int(header.payload[safe: 10] ?? 0)
        let style = styles.paragraphStyle(paraShapeID: paraShapeID, styleID: styleID)
        var decoded = DecodedHWPText(text: "", offsets: [])
        var charShapeRefs: [(start: Int, id: Int)] = []
        var contentBlocks: [ASKHWPContentBlock] = []
        var additionalParagraphs: [ASKHWPParagraph] = []
        var pageMetrics: ASKHWPPageMetrics?

        let baseLevel = header.level
        var index = 1
        while index < records.count {
            let record = records[index]
            guard record.level == baseLevel + 1 else {
                index += 1
                continue
            }
            switch record.tagID {
            case askHWP5ParaTextTag:
                decoded = decodeText(record.payload)
            case askHWP5ParaCharShapeTag:
                charShapeRefs = parseCharShapeReferences(record.payload)
            case askHWP5CtrlHeaderTag:
                let end = groupEnd(records: records, start: index)
                let controlRecords = Array(records[index..<end])
                let control = parseControl(controlRecords, ordinal: contentBlocks.count)
                contentBlocks.append(contentsOf: control.blocks)
                additionalParagraphs.append(contentsOf: control.additionalParagraphs)
                if let metrics = control.pageMetrics {
                    pageMetrics = metrics
                }
                index = end
                continue
            default:
                break
            }
            index += 1
        }

        let paragraph: ASKHWPParagraph?
        if decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paragraph = nil
        } else {
            paragraph = ASKHWPParagraph(
                index: 0,
                runs: makeRuns(
                    text: decoded.text,
                    offsets: decoded.offsets,
                    references: charShapeRefs,
                    styleID: styleID
                ),
                sourcePath: sourcePath,
                style: style
            )
        }

        return ParagraphResult(
            paragraph: paragraph,
            additionalParagraphs: additionalParagraphs,
            contentBlocks: contentBlocks,
            pageMetrics: pageMetrics
        )
    }

    private struct ParsedControl {
        let blocks: [ASKHWPContentBlock]
        let additionalParagraphs: [ASKHWPParagraph]
        let pageMetrics: ASKHWPPageMetrics?
    }

    private func parseControl(_ records: [ASKHWP5Record], ordinal: Int) -> ParsedControl {
        guard let header = records.first, header.payload.count >= 4 else {
            return ParsedControl(blocks: [], additionalParagraphs: [], pageMetrics: nil)
        }
        let controlID = asciiID(Array(header.payload.prefix(4)))
        let controlData = Array(header.payload.dropFirst(4))
        switch controlID {
        case "tbl ":
            guard let table = parseTable(controlData: controlData, records: records, ordinal: ordinal) else {
                return ParsedControl(blocks: [], additionalParagraphs: [], pageMetrics: nil)
            }
            return ParsedControl(blocks: [.table(table)], additionalParagraphs: [], pageMetrics: nil)
        case "gso ":
            return parseGeneralShape(controlData: controlData, records: records, ordinal: ordinal)
        case "eqed":
            return parseEquation(controlData: controlData, records: records, ordinal: ordinal)
        case "secd":
            return ParsedControl(
                blocks: [],
                additionalParagraphs: [],
                pageMetrics: parsePageMetrics(from: records)
            )
        case "head", "foot", "fn  ", "en  ", "tcmt":
            let nested = parseNestedParagraphs(records)
            return ParsedControl(
                blocks: nested.map { .paragraph($0) },
                additionalParagraphs: nested,
                pageMetrics: nil
            )
        default:
            return ParsedControl(blocks: [], additionalParagraphs: [], pageMetrics: nil)
        }
    }

    private func parseNestedParagraphs(_ records: [ASKHWP5Record]) -> [ASKHWPParagraph] {
        guard let listIndex = records.firstIndex(where: { $0.tagID == askHWP5ListHeaderTag }) else {
            return []
        }
        let listRecords = Array(records.dropFirst(listIndex + 1))
        return parseParagraphList(listRecords)
    }

    private func parseParagraphList(_ records: [ASKHWP5Record]) -> [ASKHWPParagraph] {
        var result: [ASKHWPParagraph] = []
        var index = 0
        while index < records.count {
            guard records[index].tagID == askHWP5ParaHeaderTag else {
                index += 1
                continue
            }
            let end = groupEnd(records: records, start: index)
            let parsed = parseParagraphGroup(Array(records[index..<end]))
            if let paragraph = parsed.paragraph {
                result.append(paragraph)
            }
            result.append(contentsOf: parsed.additionalParagraphs)
            index = end
        }
        return result
    }

    private func parseTable(
        controlData: [UInt8],
        records: [ASKHWP5Record],
        ordinal: Int
    ) -> ASKHWPTable? {
        let tableRecordIndex = records.firstIndex(where: { $0.tagID == askHWP5TableTag })
        guard let tableRecordIndex else { return nil }
        let tableData = records[tableRecordIndex].payload
        let rowCount = Int(readUInt16(tableData, at: 4) ?? 0)
        let colCount = Int(readUInt16(tableData, at: 6) ?? 0)
        let cellSpacing = hwpPoint(Int16(bitPattern: readUInt16(tableData, at: 8) ?? 0))
        let padding = ASKHWPInsets(
            top: hwpPoint(Int16(bitPattern: readUInt16(tableData, at: 14) ?? 0)),
            right: hwpPoint(Int16(bitPattern: readUInt16(tableData, at: 12) ?? 0)),
            bottom: hwpPoint(Int16(bitPattern: readUInt16(tableData, at: 16) ?? 0)),
            left: hwpPoint(Int16(bitPattern: readUInt16(tableData, at: 10) ?? 0))
        )
        let attr = readUInt32(tableData, at: 0) ?? 0
        let repeatHeader = attr & 0x04 != 0
        let width = hwpPoint(Int32(bitPattern: readUInt32(controlData, at: 12) ?? 0))

        var cells: [ASKHWPTableCell] = []
        var index = tableRecordIndex + 1
        while index < records.count {
            guard records[index].tagID == askHWP5ListHeaderTag else {
                index += 1
                continue
            }
            let end = groupEnd(records: records, start: index)
            let cellRecords = Array(records[index..<end])
            cells.append(parseTableCell(cellRecords, tableIndex: ordinal, cellIndex: cells.count))
            index = end
        }

        var rows = (0..<max(rowCount, cells.map(\.rowIndex).max().map { $0 + 1 } ?? 0)).map {
            ASKHWPTableRow(id: "row-\($0 + 1)", index: $0, cells: [])
        }
        for cell in cells.sorted(by: { lhs, rhs in
            if lhs.rowIndex != rhs.rowIndex { return lhs.rowIndex < rhs.rowIndex }
            return lhs.columnIndex < rhs.columnIndex
        }) {
            let rowIndex = min(max(cell.rowIndex, 0), max(rows.count - 1, 0))
            guard !rows.isEmpty else { continue }
            let current = rows[rowIndex]
            rows[rowIndex] = ASKHWPTableRow(
                id: current.id,
                index: current.index,
                cells: current.cells + [cell],
                height: current.height
            )
        }
        let normalizedRows = rows.isEmpty && colCount > 0
            ? [ASKHWPTableRow(id: "row-1", index: 0, cells: [])]
            : rows
        return ASKHWPTable(
            id: "table-\(ordinal + 1)",
            sourcePath: sourcePath,
            rows: normalizedRows,
            style: ASKHWPTableStyle(cellPadding: padding.horizontal / 2),
            width: width > 0 ? width : nil,
            repeatHeader: repeatHeader,
            cellSpacing: max(cellSpacing, 0),
            inMargin: padding
        )
    }

    private func parseTableCell(
        _ records: [ASKHWP5Record],
        tableIndex: Int,
        cellIndex: Int
    ) -> ASKHWPTableCell {
        let data = records.first?.payload ?? []
        let rowIndex = Int(readUInt16(data, at: 10) ?? 0)
        let columnIndex = Int(readUInt16(data, at: 8) ?? 0)
        let columnSpan = Int(readUInt16(data, at: 12) ?? 1)
        let rowSpan = Int(readUInt16(data, at: 14) ?? 1)
        let width = hwpPoint(Int32(bitPattern: readUInt32(data, at: 16) ?? 0))
        let height = hwpPoint(Int32(bitPattern: readUInt32(data, at: 20) ?? 0))
        let margin = ASKHWPInsets(
            top: hwpPoint(Int16(bitPattern: readUInt16(data, at: 28) ?? 0)),
            right: hwpPoint(Int16(bitPattern: readUInt16(data, at: 26) ?? 0)),
            bottom: hwpPoint(Int16(bitPattern: readUInt16(data, at: 30) ?? 0)),
            left: hwpPoint(Int16(bitPattern: readUInt16(data, at: 24) ?? 0))
        )
        let paragraphs = parseParagraphList(Array(records.dropFirst()))
        return ASKHWPTableCell(
            id: "table-\(tableIndex + 1)-cell-\(cellIndex + 1)",
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            rowSpan: rowSpan,
            columnSpan: columnSpan,
            width: width > 0 ? width : nil,
            height: height > 0 ? height : nil,
            paragraphs: paragraphs,
            margin: margin,
            borderFillIDRef: readUInt16(data, at: 32).map(String.init)
        )
    }

    private func parseGeneralShape(
        controlData: [UInt8],
        records: [ASKHWP5Record],
        ordinal: Int
    ) -> ParsedControl {
        let shapeRecord = records.first {
            $0.tagID == askHWP5ShapeComponentTag && $0.payload.count >= 4
        }
        let shapeID = shapeRecord.map { asciiID(Array($0.payload.prefix(4))) } ?? ""
        if shapeID == "$pic" {
            let pictureData = records.first(where: { $0.tagID == askHWP5ShapePictureTag })?.payload ?? []
            let binDataID = Int(readUInt16(pictureData, at: 71) ?? 0)
            let binaryPath = binaryPathsByStorageID[binDataID]
            let image = ASKHWPImage(
                id: "image-\(ordinal + 1)",
                sourcePath: sourcePath,
                binaryPath: binaryPath,
                referenceID: binaryPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                width: commonDimension(controlData, offset: 12),
                height: commonDimension(controlData, offset: 16)
            )
            return ParsedControl(blocks: [.image(image)], additionalParagraphs: [], pageMetrics: nil)
        }

        let kind: ASKHWPDrawObjectKind
        if records.contains(where: { $0.tagID == askHWP5ChartDataTag }) {
            kind = .chart
        } else {
            switch shapeID {
            case "$lin": kind = .line
            case "$rec": kind = .rectangle
            case "$ell": kind = .ellipse
            case "$arc": kind = .arc
            case "$pol": kind = .polygon
            case "$cur": kind = .curve
            case "$col": kind = .connectLine
            case "$con": kind = .container
            case "$ole": kind = .ole
            default:
                if records.contains(where: { $0.tagID == askHWP5ShapeOLETag }) {
                    kind = .ole
                } else {
                    kind = .unknown
                }
            }
        }
        let nestedText = parseNestedParagraphs(records).map(\.plainText).joined(separator: "\n")
        let object = makeDrawObject(
            controlData: controlData,
            kind: kind,
            text: nestedText.nonEmptyValue,
            ordinal: ordinal
        )
        return ParsedControl(blocks: [.drawObject(object)], additionalParagraphs: [], pageMetrics: nil)
    }

    private func parseEquation(
        controlData: [UInt8],
        records: [ASKHWP5Record],
        ordinal: Int
    ) -> ParsedControl {
        let equationData = records.first(where: { $0.tagID == askHWP5EquationTag })?.payload ?? []
        var reader = ASKHWP5ByteReader(bytes: Array(equationData.dropFirst(4)))
        let script = reader.readHWPString()
        let object = makeDrawObject(
            controlData: controlData,
            kind: .equation,
            text: script?.nonEmptyValue,
            ordinal: ordinal
        )
        return ParsedControl(blocks: [.drawObject(object)], additionalParagraphs: [], pageMetrics: nil)
    }

    private func makeDrawObject(
        controlData: [UInt8],
        kind: ASKHWPDrawObjectKind,
        text: String?,
        ordinal: Int
    ) -> ASKHWPDrawObject {
        let attr = readUInt32(controlData, at: 0) ?? 0
        let wrap: String?
        switch (attr >> 21) & 0x07 {
        case 1: wrap = "TOP_AND_BOTTOM"
        case 2: wrap = "BEHIND_TEXT"
        case 3: wrap = "IN_FRONT_OF_TEXT"
        default: wrap = "SQUARE"
        }
        let object = ASKHWPDrawObject(
            id: "object-\(ordinal + 1)",
            sourcePath: sourcePath,
            kind: kind,
            text: text,
            width: commonDimension(controlData, offset: 12),
            height: commonDimension(controlData, offset: 16),
            placement: ASKHWPObjectPlacement(
                treatAsChar: attr & 0x01 != 0,
                textWrap: wrap,
                allowOverlap: attr & (1 << 14) != 0,
                flowWithText: attr & (1 << 13) != 0,
                horzRelTo: relationName((attr >> 8) & 0x03),
                vertRelTo: relationName((attr >> 3) & 0x03),
                horzOffset: signedDimension(controlData, offset: 8),
                vertOffset: signedDimension(controlData, offset: 4)
            ),
            zOrder: Int(Int32(bitPattern: readUInt32(controlData, at: 20) ?? 0))
        )
        return object
    }

    private func parsePageMetrics(from records: [ASKHWP5Record]) -> ASKHWPPageMetrics? {
        guard let page = records.first(where: { $0.tagID == askHWP5PageDefTag }), page.payload.count >= 36 else {
            return nil
        }
        return ASKHWPPageMetrics.hwpUnits(
            width: Int(readUInt32(page.payload, at: 0) ?? 59528),
            height: Int(readUInt32(page.payload, at: 4) ?? 84188),
            marginTop: Int(readUInt32(page.payload, at: 16) ?? 5669),
            marginRight: Int(readUInt32(page.payload, at: 12) ?? 8504),
            marginBottom: Int(readUInt32(page.payload, at: 20) ?? 4252),
            marginLeft: Int(readUInt32(page.payload, at: 8) ?? 8504)
        )
    }

    private func makeRuns(
        text: String,
        offsets: [Int],
        references: [(start: Int, id: Int)],
        styleID: Int
    ) -> [ASKHWPTextRun] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        guard !references.isEmpty else {
            return [ASKHWPTextRun(text: text, attributes: styles.charAttributes(id: -1, styleID: styleID))]
        }
        let sorted = references.sorted { $0.start < $1.start }
        var runs: [ASKHWPTextRun] = []
        for (index, reference) in sorted.enumerated() {
            let nextStart = index + 1 < sorted.count ? sorted[index + 1].start : Int.max
            let start = outputIndex(for: reference.start, offsets: offsets, characterCount: characters.count)
            let end = nextStart == Int.max
                ? characters.count
                : outputIndex(for: nextStart, offsets: offsets, characterCount: characters.count)
            guard start < end else { continue }
            runs.append(
                ASKHWPTextRun(
                    text: String(characters[start..<end]),
                    attributes: styles.charAttributes(id: reference.id, styleID: styleID)
                )
            )
        }
        return runs.isEmpty
            ? [ASKHWPTextRun(text: text, attributes: styles.charAttributes(id: -1, styleID: styleID))]
            : runs
    }

    private func parseCharShapeReferences(_ data: [UInt8]) -> [(start: Int, id: Int)] {
        var result: [(start: Int, id: Int)] = []
        var offset = 0
        while offset >= 0, offset <= data.count, data.count - offset >= 8 {
            guard let start = readUInt32(data, at: offset), let id = readUInt32(data, at: offset + 4) else {
                break
            }
            result.append((start: Int(start), id: Int(id)))
            offset += 8
        }
        return result
    }

    private func decodeText(_ data: [UInt8]) -> DecodedHWPText {
        var result = ""
        var offsets: [Int] = []
        var byteOffset = 0
        while byteOffset >= 0, byteOffset <= data.count, data.count - byteOffset >= 2 {
            let codeUnit = readUInt16(data, at: byteOffset) ?? 0
            let codeUnitPosition = byteOffset / 2
            switch codeUnit {
            case 0:
                byteOffset += 2
            case 0x0009:
                offsets.append(codeUnitPosition)
                result.append("\t")
                byteOffset += min(16, data.count - byteOffset)
            case 0x000A:
                offsets.append(codeUnitPosition)
                result.append("\n")
                byteOffset += 2
            case 0x000D:
                byteOffset = data.count
            case 0x0001...0x0008, 0x000B...0x000C, 0x000E...0x0017:
                if codeUnit == 0x0012 {
                    offsets.append(codeUnitPosition)
                    result.append(" ")
                }
                byteOffset += min(16, data.count - byteOffset)
            case 0x0018:
                offsets.append(codeUnitPosition)
                result.append("-")
                byteOffset += 2
            case 0x0019:
                offsets.append(codeUnitPosition)
                result.append(" ")
                byteOffset += 2
            case 0x001E:
                offsets.append(codeUnitPosition)
                result.append("\u{00A0}")
                byteOffset += 2
            case 0x001F:
                offsets.append(codeUnitPosition)
                result.append("\u{2007}")
                byteOffset += 2
            case 0xD800...0xDBFF:
                guard let low = readUInt16(data, at: byteOffset + 2), (0xDC00...0xDFFF).contains(low) else {
                    byteOffset += 2
                    continue
                }
                let codePoint = 0x10000 + ((UInt32(codeUnit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                if let scalar = UnicodeScalar(codePoint) {
                    offsets.append(codeUnitPosition)
                    result.unicodeScalars.append(scalar)
                }
                byteOffset += 4
            default:
                if let scalar = UnicodeScalar(codeUnit) {
                    offsets.append(codeUnitPosition)
                    result.unicodeScalars.append(scalar)
                }
                byteOffset += 2
            }
        }
        return DecodedHWPText(text: result, offsets: offsets)
    }

    private func groupEnd(records: [ASKHWP5Record], start: Int) -> Int {
        let level = records[start].level
        var index = start + 1
        while index < records.count, records[index].level > level {
            index += 1
        }
        return index
    }

    private func outputIndex(for codeUnitOffset: Int, offsets: [Int], characterCount: Int) -> Int {
        guard !offsets.isEmpty else { return 0 }
        if let index = offsets.firstIndex(where: { $0 >= codeUnitOffset }) {
            return index
        }
        return characterCount
    }

    private func commonDimension(_ data: [UInt8], offset: Int) -> Double? {
        guard let value = readUInt32(data, at: offset), value > 0 else { return nil }
        return hwpPoint(Int32(bitPattern: value))
    }

    private func signedDimension(_ data: [UInt8], offset: Int) -> Double {
        hwpPoint(Int32(bitPattern: readUInt32(data, at: offset) ?? 0))
    }

    private func relationName(_ value: UInt32) -> String {
        switch value {
        case 1: return "PAGE"
        case 2: return "PARA"
        default: return "PAPER"
        }
    }

    private func hwpPoint(_ value: Int16) -> Double {
        Double(value) / 100.0
    }

    private func hwpPoint(_ value: Int32) -> Double {
        Double(value) / 100.0
    }

    private func readUInt16(_ data: [UInt8], at offset: Int) -> UInt16? {
        guard data.count >= 2, offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: [UInt8], at offset: Int) -> UInt32? {
        guard data.count >= 4, offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func asciiID(_ bytes: [UInt8]) -> String {
        String(bytes: Array(bytes.reversed()), encoding: .ascii) ?? ""
    }
}

private struct DecodedHWPText: Sendable, Hashable {
    let text: String
    let offsets: [Int]
}

private struct ASKHWP5ByteReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    mutating func readUInt8() -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard bytes.count >= 2, offset >= 0, offset <= bytes.count - 2 else { return nil }
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func readHWPString() -> String? {
        guard let count = readUInt16() else { return nil }
        let byteCount = Int(count) * 2
        guard offset >= 0, offset <= bytes.count, byteCount <= bytes.count - offset else { return nil }
        let end = offset + byteCount
        let values = stride(from: offset, to: end, by: 2).map {
            UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8)
        }
        offset = end
        return String(decoding: values, as: UTF16.self)
    }
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
