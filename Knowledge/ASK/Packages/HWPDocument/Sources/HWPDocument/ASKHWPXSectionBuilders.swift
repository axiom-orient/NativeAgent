import Foundation
import DocumentCore

struct ASKHWPXParsedSection: Sendable, Hashable {
  let pageMetrics: ASKHWPPageMetrics?
  let paragraphs: [ASKHWPParagraph]
  let contentBlocks: [ASKHWPContentBlock]
}

enum ParagraphTarget: Sendable, Hashable {
  case body
  case tableCell
}

enum ObjectTextTarget: Sendable, Hashable {
  case body
  case caption
}

struct TableBuilder: Sendable, Hashable {
  let id: String
  let sourcePath: String
  let depth: Int
  let style: ASKHWPTableStyle
  var width: Double?
  var rows: [ASKHWPTableRow] = []
  var repeatHeader: Bool
  var cellSpacing: Double
  var borderFillIDRef: String?
  var inMargin: ASKHWPInsets
  var outMargin: ASKHWPInsets
}

struct RowBuilder: Sendable, Hashable {
  let id: String
  var index: Int
  let depth: Int
  var height: Double?
  var cells: [ASKHWPTableCell] = []
}

struct CellBuilder: Sendable, Hashable {
  let id: String
  var rowIndex: Int
  var columnIndex: Int
  let depth: Int
  var rowSpan: Int
  var columnSpan: Int
  var width: Double?
  var height: Double?
  var margin: ASKHWPInsets
  var borderFillIDRef: String?
  var textParts: [String] = []
  var paragraphs: [ASKHWPParagraph] = []
  var nestedTables: [ASKHWPTable] = []
}

struct ImageBuilder: Sendable, Hashable {
  let id: String
  let sourcePath: String
  let depth: Int
  var binaryPath: String?
  var referenceID: String?
  var altText: String?
  var width: Double?
  var height: Double?
}

struct DrawObjectBuilder: Sendable, Hashable {
  let id: String
  let sourcePath: String
  let depth: Int
  let kind: ASKHWPDrawObjectKind
  var name: String?
  var referenceID: String?
  var variant: String?
  var width: Double?
  var height: Double?
  var textParts: [String] = []
  var captionParts: [String] = []
  var placement: ASKHWPObjectPlacement = .init()
  var style = DrawStyleBuilder()
  var geometry = DrawGeometryBuilder()
  var transform = ASKHWPShapeTransform()
  var pathCommands: [ASKHWPDrawPathCommand] = []
  var textMargin = ASKHWPInsets.zero
  var zOrder: Int = 0

  var text: String {
    textParts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  var captionText: String {
    captionParts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

struct DrawStyleBuilder: Sendable, Hashable {
  var strokeColor: String? = "#4a4a4a"
  var strokeWidth: Double = 1
  var strokeDash: String?
  var fillColor: String?
  var fillHatchColor: String?
  var fillHatchStyle: String?
  var gradientType: String?
  var gradientAngle: Double?
  var gradientColors: [String] = []
  var shadow: ASKHWPShadow?
  var lineHeadStyle: String?
  var lineTailStyle: String?
  var opacity: Double = 1

  func makeStyle() -> ASKHWPDrawStyle {
    ASKHWPDrawStyle(
      strokeColor: strokeColor,
      strokeWidth: strokeWidth,
      strokeDash: strokeDash,
      fillColor: fillColor,
      fillHatchColor: fillHatchColor,
      fillHatchStyle: fillHatchStyle,
      gradient: gradientColors.isEmpty
        ? nil : ASKHWPGradient(type: gradientType, angle: gradientAngle, colors: gradientColors),
      shadow: shadow,
      lineHeadStyle: lineHeadStyle,
      lineTailStyle: lineTailStyle,
      opacity: opacity
    )
  }
}

struct DrawGeometryBuilder: Sendable, Hashable {
  var points: [ASKCanvasPoint] = []
  var startPoint: ASKCanvasPoint?
  var endPoint: ASKCanvasPoint?
  var center: ASKCanvasPoint?
  var axis1: ASKCanvasPoint?
  var axis2: ASKCanvasPoint?

  func makeGeometry() -> ASKHWPDrawGeometry {
    ASKHWPDrawGeometry(
      points: points, startPoint: startPoint, endPoint: endPoint, center: center, axis1: axis1,
      axis2: axis2)
  }
}

struct TableParserFrame: Sendable, Hashable {
  var table: TableBuilder
  var row: RowBuilder?
  var cell: CellBuilder?
  var cellTextDepth: Int
}
