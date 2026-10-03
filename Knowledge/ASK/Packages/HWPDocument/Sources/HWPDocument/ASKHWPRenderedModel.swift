import Foundation
import DocumentCore

public struct ASKHWPLayoutConfiguration: Sendable, Hashable, Codable {
  public let defaultPageMetrics: ASKHWPPageMetrics
  public let minRenderableLineWidth: Double
  public let pageGap: Double

  public init(
    defaultPageMetrics: ASKHWPPageMetrics = .a4Portrait,
    minRenderableLineWidth: Double = 24,
    pageGap: Double = 18
  ) {
    self.defaultPageMetrics = defaultPageMetrics
    self.minRenderableLineWidth = max(minRenderableLineWidth, 1)
    self.pageGap = max(pageGap, 0)
  }
}

public struct ASKHWPRenderedDocument: Sendable, Hashable, Codable {
  public let title: String
  public let format: ASKHWPDocumentFormat
  public let pages: [ASKHWPRenderedPage]
  public let metadata: [String: String]
  public let binaryObjects: [String: ASKHWPBinaryObject]

  public init(
    title: String,
    format: ASKHWPDocumentFormat,
    pages: [ASKHWPRenderedPage],
    metadata: [String: String] = [:],
    binaryObjects: [String: ASKHWPBinaryObject] = [:]
  ) {
    self.title = title
    self.format = format
    self.pages = pages
    self.metadata = metadata
    self.binaryObjects = binaryObjects
  }

  public var textFragments: [ASKHWPRenderedTextFragment] {
    pages.flatMap(\.textFragments)
  }

  public var tableFragments: [ASKHWPRenderedTableFragment] {
    pages.flatMap { $0.tableFragments.flatMap(\.flattenedTables) }
  }

  public var imageFragments: [ASKHWPRenderedImageFragment] {
    pages.flatMap(\.imageFragments)
  }

  public var objectFragments: [ASKHWPRenderedObjectFragment] {
    pages.flatMap(\.objectFragments)
  }
}

public struct ASKHWPRenderedPage: Sendable, Hashable, Codable {
  public let index: Int
  public let sectionIndex: Int
  public let metrics: ASKHWPPageMetrics
  public let bodyTextFragments: [ASKHWPRenderedTextFragment]
  public let tableFragments: [ASKHWPRenderedTableFragment]
  public let imageFragments: [ASKHWPRenderedImageFragment]
  public let objectFragments: [ASKHWPRenderedObjectFragment]

  public init(
    index: Int,
    sectionIndex: Int,
    metrics: ASKHWPPageMetrics,
    bodyTextFragments: [ASKHWPRenderedTextFragment] = [],
    tableFragments: [ASKHWPRenderedTableFragment] = [],
    imageFragments: [ASKHWPRenderedImageFragment] = [],
    objectFragments: [ASKHWPRenderedObjectFragment] = []
  ) {
    self.index = index
    self.sectionIndex = sectionIndex
    self.metrics = metrics
    self.bodyTextFragments = bodyTextFragments
    self.tableFragments = tableFragments
    self.imageFragments = imageFragments
    self.objectFragments = objectFragments
  }

  public var textFragments: [ASKHWPRenderedTextFragment] {
    bodyTextFragments + tableFragments.flatMap { $0.allTextFragments }
  }

  public var isEmpty: Bool {
    bodyTextFragments.isEmpty && tableFragments.isEmpty && imageFragments.isEmpty
      && objectFragments.isEmpty
  }
}

extension ASKHWPRenderedTableFragment {
  fileprivate var flattenedTables: [ASKHWPRenderedTableFragment] {
    [self] + cells.flatMap { $0.nestedTables.flatMap(\.flattenedTables) }
  }

  fileprivate var allTextFragments: [ASKHWPRenderedTextFragment] {
    cells.flatMap { cell in
      cell.textFragments + cell.nestedTables.flatMap(\.allTextFragments)
    }
  }
}

public struct ASKHWPRenderedTextFragment: Sendable, Hashable, Codable {
  public let sectionIndex: Int
  public let paragraphIndex: Int
  public let runIndex: Int
  public let text: String
  public let frame: ASKCanvasRect
  public let baselineY: Double
  public let attributes: ASKHWPTextAttributes
  public let paragraphStyle: ASKHWPParagraphStyle
  public let sourcePath: String?
  public let sourceRange: ASKPageSourceRange

  public init(
    sectionIndex: Int,
    paragraphIndex: Int,
    runIndex: Int,
    text: String,
    frame: ASKCanvasRect,
    baselineY: Double,
    attributes: ASKHWPTextAttributes,
    paragraphStyle: ASKHWPParagraphStyle,
    sourcePath: String?,
    sourceRange: ASKPageSourceRange
  ) {
    self.sectionIndex = sectionIndex
    self.paragraphIndex = paragraphIndex
    self.runIndex = runIndex
    self.text = text
    self.frame = frame
    self.baselineY = baselineY
    self.attributes = attributes
    self.paragraphStyle = paragraphStyle
    self.sourcePath = sourcePath
    self.sourceRange = sourceRange
  }

  public var fontSize: Double {
    attributes.pointSize ?? paragraphStyle.basePointSize
  }
}

public struct ASKHWPRenderedTableFragment: Sendable, Hashable, Codable, Identifiable {
  public let id: String
  public let tableID: String
  public let sectionIndex: Int
  public let frame: ASKCanvasRect
  public let rowRange: ASKPageSourceRange
  public let cells: [ASKHWPRenderedTableCellFragment]
  public let style: ASKHWPTableStyle
  public let borderSegments: [ASKHWPTableBorderSegment]

  public init(
    id: String,
    tableID: String,
    sectionIndex: Int,
    frame: ASKCanvasRect,
    rowRange: ASKPageSourceRange,
    cells: [ASKHWPRenderedTableCellFragment],
    style: ASKHWPTableStyle,
    borderSegments: [ASKHWPTableBorderSegment] = []
  ) {
    self.id = id
    self.tableID = tableID
    self.sectionIndex = sectionIndex
    self.frame = frame
    self.rowRange = rowRange
    self.cells = cells
    self.style = style
    self.borderSegments = borderSegments
  }
}

public struct ASKHWPRenderedTableCellFragment: Sendable, Hashable, Codable, Identifiable {
  public let id: String
  public let rowIndex: Int
  public let columnIndex: Int
  public let rowSpan: Int
  public let columnSpan: Int
  public let frame: ASKCanvasRect
  public let textFragments: [ASKHWPRenderedTextFragment]
  public let nestedTables: [ASKHWPRenderedTableFragment]

  public init(
    id: String,
    rowIndex: Int,
    columnIndex: Int,
    rowSpan: Int,
    columnSpan: Int,
    frame: ASKCanvasRect,
    textFragments: [ASKHWPRenderedTextFragment],
    nestedTables: [ASKHWPRenderedTableFragment] = []
  ) {
    self.id = id
    self.rowIndex = rowIndex
    self.columnIndex = columnIndex
    self.rowSpan = rowSpan
    self.columnSpan = columnSpan
    self.frame = frame
    self.textFragments = textFragments
    self.nestedTables = nestedTables
  }
}

public struct ASKHWPTableBorderSegment: Sendable, Hashable, Codable {
  public let start: ASKCanvasPoint
  public let end: ASKCanvasPoint
  public let width: Double

  public init(start: ASKCanvasPoint, end: ASKCanvasPoint, width: Double) {
    self.start = start
    self.end = end
    self.width = max(width, 0)
  }
}

public struct ASKHWPRenderedImageFragment: Sendable, Hashable, Codable, Identifiable {
  public let id: String
  public let sectionIndex: Int
  public let image: ASKHWPImage
  public let frame: ASKCanvasRect
  public let binaryObject: ASKHWPBinaryObject?

  public init(
    id: String, sectionIndex: Int, image: ASKHWPImage, frame: ASKCanvasRect,
    binaryObject: ASKHWPBinaryObject? = nil
  ) {
    self.id = id
    self.sectionIndex = sectionIndex
    self.image = image
    self.frame = frame
    self.binaryObject = binaryObject
  }
}

public struct ASKHWPRenderedObjectFragment: Sendable, Hashable, Codable, Identifiable {
  public let id: String
  public let sectionIndex: Int
  public let object: ASKHWPDrawObject
  public let frame: ASKCanvasRect

  public init(id: String, sectionIndex: Int, object: ASKHWPDrawObject, frame: ASKCanvasRect) {
    self.id = id
    self.sectionIndex = sectionIndex
    self.object = object
    self.frame = frame
  }
}
