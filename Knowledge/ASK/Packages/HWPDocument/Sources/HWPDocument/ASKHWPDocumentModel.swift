import Foundation
import DocumentCore

public enum ASKHWPDocumentFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case hwp
    case hwpx

    public init?(fileExtension: String) {
        switch fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hwp": self = .hwp
        case "hwpx", "owpml": self = .hwpx
        default: return nil
        }
    }

    public static func detect(data: Data, fileURL: URL? = nil) -> ASKHWPDocumentFormat? {
        if let fileURL, let format = ASKHWPDocumentFormat(fileExtension: fileURL.pathExtension) {
            return format
        }

        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 {
            return .hwpx
        }
        if bytes == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] {
            return .hwp
        }
        return nil
    }
}

public struct ASKHWPDocument: Sendable, Hashable, Codable {
    public let format: ASKHWPDocumentFormat
    public let title: String
    public let sections: [ASKHWPSection]
    public let metadata: [String: String]
    public let binaryObjects: [String: ASKHWPBinaryObject]

    public init(
        format: ASKHWPDocumentFormat,
        title: String,
        sections: [ASKHWPSection],
        metadata: [String: String] = [:],
        binaryObjects: [String: ASKHWPBinaryObject] = [:]
    ) {
        self.format = format
        self.title = title
        self.sections = sections
        self.metadata = metadata
        self.binaryObjects = binaryObjects
    }

    public var paragraphs: [ASKHWPParagraph] {
        sections.flatMap(\.paragraphs)
    }

    public var tables: [ASKHWPTable] {
        sections.flatMap(\.tables)
    }

    public var images: [ASKHWPImage] {
        sections.flatMap(\.images)
    }

    public var drawObjects: [ASKHWPDrawObject] {
        sections.flatMap(\.drawObjects)
    }

    public var plainText: String {
        sections.map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

public struct ASKHWPSection: Sendable, Hashable, Codable {
    public let index: Int
    public let title: String?
    public let sourcePath: String?
    public let pageMetrics: ASKHWPPageMetrics?
    public let paragraphs: [ASKHWPParagraph]
    public let contentBlocks: [ASKHWPContentBlock]

    public init(
        index: Int,
        title: String? = nil,
        sourcePath: String? = nil,
        pageMetrics: ASKHWPPageMetrics? = nil,
        paragraphs: [ASKHWPParagraph],
        contentBlocks: [ASKHWPContentBlock]? = nil
    ) {
        self.index = index
        self.title = title
        self.sourcePath = sourcePath
        self.pageMetrics = pageMetrics
        self.paragraphs = paragraphs
        self.contentBlocks = contentBlocks ?? paragraphs.map { .paragraph($0) }
    }

    public var tables: [ASKHWPTable] {
        contentBlocks.flatMap { block -> [ASKHWPTable] in
            if case let .table(table) = block { return table.flattenedTables }
            return []
        }
    }

    public var images: [ASKHWPImage] {
        contentBlocks.compactMap { block in
            if case let .image(image) = block { return image }
            return nil
        }
    }

    public var drawObjects: [ASKHWPDrawObject] {
        contentBlocks.compactMap { block in
            if case let .drawObject(object) = block { return object }
            return nil
        }
    }

    public var plainText: String {
        contentBlocks.map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public enum ASKHWPContentBlock: Sendable, Hashable, Codable {
    case paragraph(ASKHWPParagraph)
    case table(ASKHWPTable)
    case image(ASKHWPImage)
    case drawObject(ASKHWPDrawObject)

    public var plainText: String {
        switch self {
        case .paragraph(let paragraph):
            return paragraph.plainText
        case .table(let table):
            return table.plainText
        case .image(let image):
            return image.altText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? ""
        case .drawObject(let object):
            return object.plainText
        }
    }
}

public struct ASKHWPParagraph: Sendable, Hashable, Codable {
    public let index: Int
    public let runs: [ASKHWPTextRun]
    public let sourcePath: String?
    public let style: ASKHWPParagraphStyle

    public init(
        index: Int,
        runs: [ASKHWPTextRun],
        sourcePath: String? = nil,
        style: ASKHWPParagraphStyle = .body
    ) {
        self.index = index
        self.runs = runs
        self.sourcePath = sourcePath
        self.style = style
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }
}

public struct ASKHWPTextRun: Sendable, Hashable, Codable {
    public let text: String
    public let attributes: ASKHWPTextAttributes

    public init(text: String, attributes: ASKHWPTextAttributes = .init()) {
        self.text = text
        self.attributes = attributes
    }
}

public struct ASKHWPTextAttributes: Sendable, Hashable, Codable {
    public let styleID: String?
    public let charShapeID: String?
    public let pointSize: Double?
    public let isBold: Bool
    public let isItalic: Bool

    public init(
        styleID: String? = nil,
        charShapeID: String? = nil,
        pointSize: Double? = nil,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.styleID = styleID
        self.charShapeID = charShapeID
        self.pointSize = pointSize
        self.isBold = isBold
        self.isItalic = isItalic
    }

    public func merged(overriding other: ASKHWPTextAttributes) -> ASKHWPTextAttributes {
        ASKHWPTextAttributes(
            styleID: other.styleID ?? styleID,
            charShapeID: other.charShapeID ?? charShapeID,
            pointSize: other.pointSize ?? pointSize,
            isBold: isBold || other.isBold,
            isItalic: isItalic || other.isItalic
        )
    }
}

public enum ASKHWPParagraphAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case left
    case center
    case right
    case justified
}

public struct ASKHWPParagraphStyle: Sendable, Hashable, Codable {
    public let styleID: String?
    public let paragraphShapeID: String?
    public let alignment: ASKHWPParagraphAlignment
    public let basePointSize: Double
    public let lineHeightMultiple: Double
    public let spacingBefore: Double
    public let spacingAfter: Double
    public let leftIndent: Double
    public let rightIndent: Double
    public let firstLineIndent: Double

    public init(
        styleID: String? = nil,
        paragraphShapeID: String? = nil,
        alignment: ASKHWPParagraphAlignment = .left,
        basePointSize: Double = 12,
        lineHeightMultiple: Double = 1.45,
        spacingBefore: Double = 0,
        spacingAfter: Double = 8,
        leftIndent: Double = 0,
        rightIndent: Double = 0,
        firstLineIndent: Double = 0
    ) {
        self.styleID = styleID
        self.paragraphShapeID = paragraphShapeID
        self.alignment = alignment
        self.basePointSize = basePointSize
        self.lineHeightMultiple = max(lineHeightMultiple, 1)
        self.spacingBefore = max(spacingBefore, 0)
        self.spacingAfter = max(spacingAfter, 0)
        self.leftIndent = max(leftIndent, 0)
        self.rightIndent = max(rightIndent, 0)
        self.firstLineIndent = firstLineIndent
    }

    public static let body = ASKHWPParagraphStyle()

    public var lineHeight: Double {
        basePointSize * lineHeightMultiple
    }
}

public struct ASKHWPTable: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let sourcePath: String?
    public let rows: [ASKHWPTableRow]
    public let style: ASKHWPTableStyle
    public let width: Double?
    public let repeatHeader: Bool
    public let cellSpacing: Double
    public let borderFillIDRef: String?
    public let inMargin: ASKHWPInsets
    public let outMargin: ASKHWPInsets

    public init(
        id: String,
        sourcePath: String? = nil,
        rows: [ASKHWPTableRow],
        style: ASKHWPTableStyle = .init(),
        width: Double? = nil,
        repeatHeader: Bool = false,
        cellSpacing: Double = 0,
        borderFillIDRef: String? = nil,
        inMargin: ASKHWPInsets = .zero,
        outMargin: ASKHWPInsets = .zero
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.rows = rows
        self.style = style
        self.width = width
        self.repeatHeader = repeatHeader
        self.cellSpacing = max(cellSpacing, 0)
        self.borderFillIDRef = borderFillIDRef
        self.inMargin = inMargin
        self.outMargin = outMargin
    }

    public var plainText: String {
        rows.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var columnCount: Int {
        rows.map { row in
            row.cells.reduce(0) { $0 + max($1.columnSpan, 1) }
        }.max() ?? 0
    }

    public var flattenedTables: [ASKHWPTable] {
        [self] + rows.flatMap { row in
            row.cells.flatMap { cell in cell.nestedTables.flatMap(\.flattenedTables) }
        }
    }
}

public struct ASKHWPTableRow: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let index: Int
    public let cells: [ASKHWPTableCell]
    public let height: Double?

    public init(id: String, index: Int, cells: [ASKHWPTableCell], height: Double? = nil) {
        self.id = id
        self.index = index
        self.cells = cells
        self.height = height
    }

    public var plainText: String {
        cells.map(\.plainText).joined(separator: "\t")
    }
}

public struct ASKHWPTableCell: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let rowIndex: Int
    public let columnIndex: Int
    public let rowSpan: Int
    public let columnSpan: Int
    public let width: Double?
    public let height: Double?
    public let paragraphs: [ASKHWPParagraph]
    public let margin: ASKHWPInsets
    public let borderFillIDRef: String?
    public let nestedTables: [ASKHWPTable]

    public init(
        id: String,
        rowIndex: Int,
        columnIndex: Int,
        rowSpan: Int = 1,
        columnSpan: Int = 1,
        width: Double? = nil,
        height: Double? = nil,
        paragraphs: [ASKHWPParagraph],
        margin: ASKHWPInsets = .zero,
        borderFillIDRef: String? = nil,
        nestedTables: [ASKHWPTable] = []
    ) {
        self.id = id
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.rowSpan = max(rowSpan, 1)
        self.columnSpan = max(columnSpan, 1)
        self.width = width
        self.height = height
        self.paragraphs = paragraphs
        self.margin = margin
        self.borderFillIDRef = borderFillIDRef
        self.nestedTables = nestedTables
    }

    public var plainText: String {
        (paragraphs.map(\.plainText) + nestedTables.map(\.plainText))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public struct ASKHWPTableStyle: Sendable, Hashable, Codable {
    public let borderWidth: Double
    public let cellPadding: Double
    public let spacingAfter: Double

    public init(borderWidth: Double = 0.75, cellPadding: Double = 4, spacingAfter: Double = 8) {
        self.borderWidth = max(borderWidth, 0)
        self.cellPadding = max(cellPadding, 0)
        self.spacingAfter = max(spacingAfter, 0)
    }
}

public struct ASKHWPInsets: Sendable, Hashable, Codable {
    public let top: Double
    public let right: Double
    public let bottom: Double
    public let left: Double

    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = max(top, 0)
        self.right = max(right, 0)
        self.bottom = max(bottom, 0)
        self.left = max(left, 0)
    }

    public static let zero = ASKHWPInsets()

    public var horizontal: Double { left + right }
    public var vertical: Double { top + bottom }
}

public struct ASKHWPImage: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let sourcePath: String?
    public let binaryPath: String?
    public let referenceID: String?
    public let altText: String?
    public let width: Double?
    public let height: Double?

    public init(
        id: String,
        sourcePath: String? = nil,
        binaryPath: String? = nil,
        referenceID: String? = nil,
        altText: String? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.binaryPath = binaryPath
        self.referenceID = referenceID
        self.altText = altText
        self.width = width
        self.height = height
    }
}

public enum ASKHWPDrawObjectKind: String, Sendable, Hashable, Codable, CaseIterable {
    case rectangle
    case ellipse
    case line
    case polygon
    case curve
    case connectLine
    case arc
    case container
    case equation
    case chart
    case ole
    case unknown
}

public struct ASKHWPDrawObject: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let sourcePath: String?
    public let kind: ASKHWPDrawObjectKind
    public let name: String?
    public let referenceID: String?
    public let text: String?
    public let width: Double?
    public let height: Double?
    public let variant: String?
    public let placement: ASKHWPObjectPlacement
    public let style: ASKHWPDrawStyle
    public let geometry: ASKHWPDrawGeometry
    public let transform: ASKHWPShapeTransform
    public let pathCommands: [ASKHWPDrawPathCommand]
    public let textMargin: ASKHWPInsets
    public let captionText: String?
    public let zOrder: Int

    public init(
        id: String,
        sourcePath: String? = nil,
        kind: ASKHWPDrawObjectKind,
        name: String? = nil,
        referenceID: String? = nil,
        text: String? = nil,
        width: Double? = nil,
        height: Double? = nil,
        variant: String? = nil,
        placement: ASKHWPObjectPlacement = .init(),
        style: ASKHWPDrawStyle = .init(),
        geometry: ASKHWPDrawGeometry = .init(),
        transform: ASKHWPShapeTransform = .init(),
        pathCommands: [ASKHWPDrawPathCommand] = [],
        textMargin: ASKHWPInsets = .zero,
        captionText: String? = nil,
        zOrder: Int = 0
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.kind = kind
        self.name = name
        self.referenceID = referenceID
        self.text = text
        self.width = width
        self.height = height
        self.variant = variant
        self.placement = placement
        self.style = style
        self.geometry = geometry
        self.transform = transform
        self.pathCommands = pathCommands
        self.textMargin = textMargin
        self.captionText = captionText
        self.zOrder = zOrder
    }

    public var plainText: String {
        [text, captionText, name, referenceID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue }
            .first ?? ""
    }
}

public struct ASKHWPObjectPlacement: Sendable, Hashable, Codable {
    public let treatAsChar: Bool
    public let textWrap: String?
    public let textFlow: String?
    public let allowOverlap: Bool
    public let flowWithText: Bool
    public let horzRelTo: String?
    public let vertRelTo: String?
    public let horzOffset: Double
    public let vertOffset: Double

    public init(
        treatAsChar: Bool = true,
        textWrap: String? = nil,
        textFlow: String? = nil,
        allowOverlap: Bool = false,
        flowWithText: Bool = false,
        horzRelTo: String? = nil,
        vertRelTo: String? = nil,
        horzOffset: Double = 0,
        vertOffset: Double = 0
    ) {
        self.treatAsChar = treatAsChar
        self.textWrap = textWrap
        self.textFlow = textFlow
        self.allowOverlap = allowOverlap
        self.flowWithText = flowWithText
        self.horzRelTo = horzRelTo
        self.vertRelTo = vertRelTo
        self.horzOffset = horzOffset
        self.vertOffset = vertOffset
    }
}

public struct ASKHWPDrawStyle: Sendable, Hashable, Codable {
    public let strokeColor: String?
    public let strokeWidth: Double
    public let strokeDash: String?
    public let fillColor: String?
    public let fillHatchColor: String?
    public let fillHatchStyle: String?
    public let gradient: ASKHWPGradient?
    public let shadow: ASKHWPShadow?
    public let lineHeadStyle: String?
    public let lineTailStyle: String?
    public let opacity: Double

    public init(
        strokeColor: String? = "#4a4a4a",
        strokeWidth: Double = 1,
        strokeDash: String? = nil,
        fillColor: String? = nil,
        fillHatchColor: String? = nil,
        fillHatchStyle: String? = nil,
        gradient: ASKHWPGradient? = nil,
        shadow: ASKHWPShadow? = nil,
        lineHeadStyle: String? = nil,
        lineTailStyle: String? = nil,
        opacity: Double = 1
    ) {
        self.strokeColor = strokeColor
        self.strokeWidth = max(strokeWidth, 0)
        self.strokeDash = strokeDash
        self.fillColor = fillColor
        self.fillHatchColor = fillHatchColor
        self.fillHatchStyle = fillHatchStyle
        self.gradient = gradient
        self.shadow = shadow
        self.lineHeadStyle = lineHeadStyle
        self.lineTailStyle = lineTailStyle
        self.opacity = min(max(opacity, 0), 1)
    }
}

public struct ASKHWPGradient: Sendable, Hashable, Codable {
    public let type: String?
    public let angle: Double?
    public let colors: [String]

    public init(type: String? = nil, angle: Double? = nil, colors: [String] = []) {
        self.type = type
        self.angle = angle
        self.colors = colors
    }
}

public struct ASKHWPShadow: Sendable, Hashable, Codable {
    public let type: String?
    public let color: String?
    public let offsetX: Double
    public let offsetY: Double
    public let alpha: Double

    public init(type: String? = nil, color: String? = nil, offsetX: Double = 0, offsetY: Double = 0, alpha: Double = 1) {
        self.type = type
        self.color = color
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.alpha = min(max(alpha, 0), 1)
    }
}

public struct ASKHWPDrawGeometry: Sendable, Hashable, Codable {
    public let points: [ASKCanvasPoint]
    public let startPoint: ASKCanvasPoint?
    public let endPoint: ASKCanvasPoint?
    public let center: ASKCanvasPoint?
    public let axis1: ASKCanvasPoint?
    public let axis2: ASKCanvasPoint?

    public init(
        points: [ASKCanvasPoint] = [],
        startPoint: ASKCanvasPoint? = nil,
        endPoint: ASKCanvasPoint? = nil,
        center: ASKCanvasPoint? = nil,
        axis1: ASKCanvasPoint? = nil,
        axis2: ASKCanvasPoint? = nil
    ) {
        self.points = points
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.center = center
        self.axis1 = axis1
        self.axis2 = axis2
    }
}

public struct ASKHWPShapeTransform: Sendable, Hashable, Codable {
    public let rotationDegrees: Double
    public let center: ASKCanvasPoint?
    public let flipHorizontal: Bool
    public let flipVertical: Bool

    public init(
        rotationDegrees: Double = 0,
        center: ASKCanvasPoint? = nil,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) {
        self.rotationDegrees = rotationDegrees
        self.center = center
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

public struct ASKHWPDrawPathCommand: Sendable, Hashable, Codable {
    public let command: String
    public let points: [ASKCanvasPoint]
    public let segmentType: String?

    public init(command: String, points: [ASKCanvasPoint] = [], segmentType: String? = nil) {
        self.command = command
        self.points = points
        self.segmentType = segmentType
    }
}

public struct ASKHWPBinaryObject: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let path: String
    public let mediaType: String?
    public let data: Data?

    public init(id: String, path: String, mediaType: String? = nil, data: Data? = nil) {
        self.id = id
        self.path = path
        self.mediaType = mediaType
        self.data = data
    }
}

public struct ASKHWPPageMetrics: Sendable, Hashable, Codable {
    public let width: Double
    public let height: Double
    public let marginTop: Double
    public let marginRight: Double
    public let marginBottom: Double
    public let marginLeft: Double

    public init(
        width: Double,
        height: Double,
        marginTop: Double,
        marginRight: Double,
        marginBottom: Double,
        marginLeft: Double
    ) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.marginTop = max(marginTop, 0)
        self.marginRight = max(marginRight, 0)
        self.marginBottom = max(marginBottom, 0)
        self.marginLeft = max(marginLeft, 0)
    }

    public static let a4Portrait = ASKHWPPageMetrics(
        width: 595.27,
        height: 841.89,
        marginTop: 56.7,
        marginRight: 56.7,
        marginBottom: 56.7,
        marginLeft: 56.7
    )

    public static func hwpUnits(
        width: Int,
        height: Int,
        marginTop: Int,
        marginRight: Int,
        marginBottom: Int,
        marginLeft: Int
    ) -> ASKHWPPageMetrics {
        ASKHWPPageMetrics(
            width: hwpUnitToPoint(width),
            height: hwpUnitToPoint(height),
            marginTop: hwpUnitToPoint(marginTop),
            marginRight: hwpUnitToPoint(marginRight),
            marginBottom: hwpUnitToPoint(marginBottom),
            marginLeft: hwpUnitToPoint(marginLeft)
        )
    }

    public var contentX: Double { marginLeft }
    public var contentY: Double { marginTop }
    public var contentWidth: Double { max(width - marginLeft - marginRight, 1) }
    public var contentHeight: Double { max(height - marginTop - marginBottom, 1) }

    public static func hwpUnitToPoint(_ value: Int) -> Double {
        Double(value) / 100.0
    }
}
