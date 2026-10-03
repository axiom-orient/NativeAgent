import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

struct ASKHWPXStyleCatalog: Sendable, Hashable {
  fileprivate struct CharDefinition: Sendable, Hashable {
    let pointSize: Double
    let isBold: Bool
    let isItalic: Bool
  }

  fileprivate struct ParaDefinition: Sendable, Hashable {
    let alignment: ASKHWPParagraphAlignment
    let lineHeightMultiple: Double
    let spacingBefore: Double
    let spacingAfter: Double
    let leftIndent: Double
    let rightIndent: Double
    let firstLineIndent: Double
  }

  fileprivate struct StyleDefinition: Sendable, Hashable {
    let paraShapeID: String
    let charShapeID: String
  }

  private let chars: [String: CharDefinition]
  private let paras: [String: ParaDefinition]
  private let styles: [String: StyleDefinition]

  private init(
    chars: [String: CharDefinition],
    paras: [String: ParaDefinition],
    styles: [String: StyleDefinition]
  ) {
    self.chars = chars
    self.paras = paras
    self.styles = styles
  }

  static let empty = ASKHWPXStyleCatalog(chars: [:], paras: [:], styles: [:])

  var charStyleCount: Int { chars.count }
  var paragraphStyleCount: Int { paras.count }

  init(data: Data) throws {
    let parser = ASKHWPXStyleXMLParser(data: data)
    let result = try parser.parse()
    self.init(chars: result.chars, paras: result.paras, styles: result.styles)
  }

  func resolve(paragraph: ASKHWPParagraph) -> ASKHWPParagraph {
    let inlineStyle = paragraph.style
    let styleDefinition = inlineStyle.styleID.flatMap { styles[$0] }
    let paraID = inlineStyle.paragraphShapeID ?? styleDefinition?.paraShapeID
    let para = paraID.flatMap { paras[$0] }
    let charID = styleDefinition?.charShapeID
    let char = charID.flatMap { chars[$0] }

    let resolvedStyle = ASKHWPParagraphStyle(
      styleID: inlineStyle.styleID,
      paragraphShapeID: paraID,
      alignment: para?.alignment ?? inlineStyle.alignment,
      basePointSize: char?.pointSize ?? inlineStyle.basePointSize,
      lineHeightMultiple: para?.lineHeightMultiple ?? inlineStyle.lineHeightMultiple,
      spacingBefore: para?.spacingBefore ?? inlineStyle.spacingBefore,
      spacingAfter: para?.spacingAfter ?? inlineStyle.spacingAfter,
      leftIndent: para?.leftIndent ?? inlineStyle.leftIndent,
      rightIndent: para?.rightIndent ?? inlineStyle.rightIndent,
      firstLineIndent: para?.firstLineIndent ?? inlineStyle.firstLineIndent
    )
    let resolvedRuns = paragraph.runs.map { run in
      guard let charShapeID = run.attributes.charShapeID, let definition = chars[charShapeID] else {
        return run
      }
      return ASKHWPTextRun(
        text: run.text,
        attributes: ASKHWPTextAttributes(
          styleID: run.attributes.styleID,
          charShapeID: charShapeID,
          pointSize: run.attributes.pointSize ?? definition.pointSize,
          isBold: run.attributes.isBold || definition.isBold,
          isItalic: run.attributes.isItalic || definition.isItalic
        )
      )
    }
    return ASKHWPParagraph(
      index: paragraph.index,
      runs: resolvedRuns,
      sourcePath: paragraph.sourcePath,
      style: resolvedStyle
    )
  }
}

private final class ASKHWPXStyleXMLParser: NSObject, XMLParserDelegate {
  struct Result {
    var chars: [String: ASKHWPXStyleCatalog.CharDefinition] = [:]
    var paras: [String: ASKHWPXStyleCatalog.ParaDefinition] = [:]
    var styles: [String: ASKHWPXStyleCatalog.StyleDefinition] = [:]
  }

  private let data: Data
  private var result = Result()
  private var parserError: Error?
  private var currentChar: (id: String, pointSize: Double, bold: Bool, italic: Bool)?
  private var currentPara: (
    id: String,
    alignment: ASKHWPParagraphAlignment,
    lineHeightMultiple: Double,
    spacingBefore: Double,
    spacingAfter: Double,
    leftIndent: Double,
    rightIndent: Double,
    firstLineIndent: Double
  )?

  init(data: Data) {
    self.data = data
  }

  func parse() throws -> Result {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      throw ASKHWPError.xmlParsingFailed(
        "Contents/header.xml: \(parserError?.localizedDescription ?? parser.parserError?.localizedDescription ?? "Unknown XML parser error.")"
      )
    }
    finishChar()
    finishPara()
    return result
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    parserError = parseError
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let localName = xmlLocalName(elementName).lowercased()
    let attributes = AttributeLookup(attributeDict)
    switch localName {
    case "charpr":
      finishChar()
      guard let id = attributes.string(["id"]) else { return }
      currentChar = (
        id: id,
        pointSize: attributes.pointSize(["height"]) ?? 12,
        bold: false,
        italic: false
      )
    case "bold":
      currentChar?.bold = true
    case "italic":
      currentChar?.italic = true
    case "parapr":
      finishPara()
      guard let id = attributes.string(["id"]) else { return }
      currentPara = (
        id: id,
        alignment: .left,
        lineHeightMultiple: ASKHWPParagraphStyle.body.lineHeightMultiple,
        spacingBefore: 0,
        spacingAfter: ASKHWPParagraphStyle.body.spacingAfter,
        leftIndent: 0,
        rightIndent: 0,
        firstLineIndent: 0
      )
    case "align":
      currentPara?.alignment = ASKHWPXAttributeDecoder.alignment(
        from: attributes.string(["horizontal", "align"])
      )
    case "linespacing":
      if let value = attributes.double(["value"]) {
        currentPara?.lineHeightMultiple = max(value / 100.0, 1)
      }
    case "intent":
      currentPara?.firstLineIndent = attributes.hwpUnitPoint(["value"]) ?? 0
    case "left":
      currentPara?.leftIndent = attributes.hwpUnitPoint(["value"]) ?? 0
    case "right":
      currentPara?.rightIndent = attributes.hwpUnitPoint(["value"]) ?? 0
    case "prev":
      currentPara?.spacingBefore = attributes.hwpUnitPoint(["value"]) ?? 0
    case "next":
      currentPara?.spacingAfter = attributes.hwpUnitPoint(["value"]) ?? 0
    case "style":
      guard let id = attributes.string(["id"]),
            let paraShapeID = attributes.string(["paraPrIDRef", "paraShapeIDRef"]),
            let charShapeID = attributes.string(["charPrIDRef", "charShapeIDRef"])
      else { return }
      result.styles[id] = .init(paraShapeID: paraShapeID, charShapeID: charShapeID)
    default:
      break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch xmlLocalName(elementName).lowercased() {
    case "charpr": finishChar()
    case "parapr": finishPara()
    default: break
    }
  }

  private func finishChar() {
    guard let currentChar else { return }
    result.chars[currentChar.id] = .init(
      pointSize: currentChar.pointSize,
      isBold: currentChar.bold,
      isItalic: currentChar.italic
    )
    self.currentChar = nil
  }

  private func finishPara() {
    guard let currentPara else { return }
    result.paras[currentPara.id] = .init(
      alignment: currentPara.alignment,
      lineHeightMultiple: currentPara.lineHeightMultiple,
      spacingBefore: currentPara.spacingBefore,
      spacingAfter: currentPara.spacingAfter,
      leftIndent: currentPara.leftIndent,
      rightIndent: currentPara.rightIndent,
      firstLineIndent: currentPara.firstLineIndent
    )
    self.currentPara = nil
  }
}
