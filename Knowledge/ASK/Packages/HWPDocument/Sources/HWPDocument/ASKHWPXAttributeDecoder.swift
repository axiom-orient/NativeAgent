import DocumentCore
import Foundation

enum ASKHWPXAttributeDecoder {
  static func startsTable(_ localName: String) -> Bool {
    localName == "tbl" || localName == "table"
  }

  static func startsTableRow(_ localName: String) -> Bool {
    localName == "tr" || localName == "row"
  }

  static func startsTableCell(_ localName: String) -> Bool {
    localName == "tc" || localName == "cell" || localName == "td"
  }

  static func startsImage(_ localName: String) -> Bool {
    localName == "pic" || localName == "picture" || localName == "image" || localName == "img"
  }

  static func startsDrawObject(_ localName: String) -> Bool {
    switch localName {
    case "rect", "rectangle", "ellipse", "circle", "line", "polygon", "polyline", "curve",
      "connectline", "arc", "container", "shape", "equation", "chart", "ole", "object":
      return true
    default:
      return false
    }
  }

  static func drawObjectKind(_ localName: String) -> ASKHWPDrawObjectKind {
    switch localName {
    case "rect", "rectangle": return .rectangle
    case "ellipse", "circle": return .ellipse
    case "line": return .line
    case "polygon", "polyline": return .polygon
    case "curve": return .curve
    case "connectline": return .connectLine
    case "arc": return .arc
    case "container", "shape": return .container
    case "equation": return .equation
    case "chart": return .chart
    case "ole", "object": return .ole
    default: return .unknown
    }
  }

  static func imageBinaryPath(_ attributes: AttributeLookup) -> String? {
    let raw = attributes.string([
      "binaryItemIDRef", "binaryItemIdRef", "binItemIDRef", "binDataIDRef", "refID", "refId",
      "href", "path",
    ])
    guard let raw else { return nil }
    return raw
  }

  static func pointDimension(_ attributes: AttributeLookup, keys: [String]) -> Double? {
    attributes.hwpUnitPoint(keys) ?? attributes.double(keys)
  }

  static func insets(from attributes: AttributeLookup) -> ASKHWPInsets {
    ASKHWPInsets(
      top: pointDimension(attributes, keys: ["top", "marginTop", "topMargin"]) ?? 0,
      right: pointDimension(attributes, keys: ["right", "marginRight", "rightMargin"]) ?? 0,
      bottom: pointDimension(attributes, keys: ["bottom", "marginBottom", "bottomMargin"]) ?? 0,
      left: pointDimension(attributes, keys: ["left", "marginLeft", "leftMargin"]) ?? 0
    )
  }

  static func point(from attributes: AttributeLookup) -> ASKCanvasPoint? {
    let x =
      pointDimension(attributes, keys: ["x", "x1", "posX"])
      ?? attributes.double(["x", "x1", "posX"])
    let y =
      pointDimension(attributes, keys: ["y", "y1", "posY"])
      ?? attributes.double(["y", "y1", "posY"])
    guard let x, let y else { return nil }
    return ASKCanvasPoint(x: x, y: y)
  }

  static func pointFromXY(
    _ attributes: AttributeLookup,
    xKeys: [String] = ["x", "x1", "posX"],
    yKeys: [String] = ["y", "y1", "posY"]
  ) -> ASKCanvasPoint? {
    let x = pointDimension(attributes, keys: xKeys) ?? attributes.double(xKeys)
    let y = pointDimension(attributes, keys: yKeys) ?? attributes.double(yKeys)
    guard let x, let y else { return nil }
    return ASKCanvasPoint(x: x, y: y)
  }

  static func normalizedRotationDegrees(_ raw: Double) -> Double {
    abs(raw) > 360 ? raw / 100.0 : raw
  }

  static func placement(from attributes: AttributeLookup) -> ASKHWPObjectPlacement {
    ASKHWPObjectPlacement(
      treatAsChar: attributes.bool(["treatAsChar"]) ?? true,
      textWrap: attributes.string(["textWrap", "wrapStyle"]),
      textFlow: attributes.string(["textFlow", "flow"]),
      allowOverlap: attributes.bool(["allowOverlap"]) ?? false,
      flowWithText: attributes.bool(["flowWithText"]) ?? false,
      horzRelTo: attributes.string(["horzRelTo", "horizontalRelTo"]),
      vertRelTo: attributes.string(["vertRelTo", "verticalRelTo"]),
      horzOffset: pointDimension(attributes, keys: ["horzOffset", "x", "offsetX"]) ?? 0,
      vertOffset: pointDimension(attributes, keys: ["vertOffset", "y", "offsetY"]) ?? 0
    )
  }

  static func normalizedColor(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    if value.hasPrefix("#") { return value }
    if value.hasPrefix("0x") || value.hasPrefix("0X") {
      value.removeFirst(2)
    }
    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard value.count == 6, value.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) else {
      return raw
    }
    return "#\(value)"
  }

  static func dashPattern(from raw: String?) -> String? {
    switch raw?.lowercased() {
    case "dash", "dashed": return "6 4"
    case "dot", "dotted": return "2 3"
    case "dashdot", "dash-dot": return "6 3 2 3"
    case "longdash", "long-dash": return "10 4"
    default: return nil
    }
  }

  static func paragraphStyle(from attributes: AttributeLookup) -> ASKHWPParagraphStyle {
    ASKHWPParagraphStyle(
      styleID: attributes.string(["styleIDRef", "styleIdRef", "styleID", "styleId"]),
      paragraphShapeID: attributes.string([
        "paraPrIDRef", "paraPrIdRef", "paraShapeIDRef", "paraShapeIdRef",
      ]),
      alignment: alignment(
        from: attributes.string(["align", "alignment", "horizontalAlign", "textAlign"])),
      basePointSize: attributes.pointSize(["fontSize", "pointSize", "height"])
        ?? ASKHWPParagraphStyle.body.basePointSize,
      lineHeightMultiple: attributes.double([
        "lineHeightMultiple", "lineSpacing", "lineSpacingPercent",
      ]).map { max($0 / 100.0, 1.0) } ?? ASKHWPParagraphStyle.body.lineHeightMultiple,
      spacingBefore: attributes.hwpUnitPoint(["spacingBefore", "marginTop", "prev", "before"])
        ?? ASKHWPParagraphStyle.body.spacingBefore,
      spacingAfter: attributes.hwpUnitPoint(["spacingAfter", "marginBottom", "next", "after"])
        ?? ASKHWPParagraphStyle.body.spacingAfter,
      leftIndent: attributes.hwpUnitPoint(["leftIndent", "indentLeft", "marginLeft", "left"]) ?? 0,
      rightIndent: attributes.hwpUnitPoint(["rightIndent", "indentRight", "marginRight", "right"])
        ?? 0,
      firstLineIndent: attributes.hwpUnitPoint(["firstLineIndent", "indent", "firstLine"]) ?? 0
    )
  }

  static func textAttributes(from attributes: AttributeLookup) -> ASKHWPTextAttributes {
    ASKHWPTextAttributes(
      styleID: attributes.string(["styleIDRef", "styleIdRef", "styleID", "styleId"]),
      charShapeID: attributes.string([
        "charPrIDRef", "charPrIdRef", "charShapeIDRef", "charShapeIdRef",
      ]),
      pointSize: attributes.pointSize(["fontSize", "pointSize", "height"]),
      isBold: attributes.bool(["bold", "isBold"]) ?? false,
      isItalic: attributes.bool(["italic", "isItalic"]) ?? false
    )
  }

  static func alignment(from rawValue: String?) -> ASKHWPParagraphAlignment {
    switch rawValue?.lowercased() {
    case "center", "middle": return .center
    case "right", "end": return .right
    case "justify", "justified", "distribute": return .justified
    default: return .left
    }
  }
}

extension ASKHWPObjectPlacement {
  func merged(with other: ASKHWPObjectPlacement) -> ASKHWPObjectPlacement {
    ASKHWPObjectPlacement(
      treatAsChar: other.treatAsChar,
      textWrap: other.textWrap ?? textWrap,
      textFlow: other.textFlow ?? textFlow,
      allowOverlap: other.allowOverlap || allowOverlap,
      flowWithText: other.flowWithText || flowWithText,
      horzRelTo: other.horzRelTo ?? horzRelTo,
      vertRelTo: other.vertRelTo ?? vertRelTo,
      horzOffset: other.horzOffset == 0 ? horzOffset : other.horzOffset,
      vertOffset: other.vertOffset == 0 ? vertOffset : other.vertOffset
    )
  }
}
