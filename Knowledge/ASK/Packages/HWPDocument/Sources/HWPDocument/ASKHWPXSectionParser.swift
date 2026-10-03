import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

final class ASKHWPXSectionXMLParser: NSObject, XMLParserDelegate {
  private let sourcePath: String
  private let styles: ASKHWPXStyleCatalog
  private var accumulator: ASKHWPXSectionAccumulator
  private var parserError: Error?

  init(sourcePath: String, styles: ASKHWPXStyleCatalog = .empty) {
    self.sourcePath = sourcePath
    self.styles = styles
    self.accumulator = ASKHWPXSectionAccumulator(sourcePath: sourcePath, styles: styles)
    super.init()
  }

  func parse(data: Data) throws -> ASKHWPXParsedSection {
    accumulator = ASKHWPXSectionAccumulator(sourcePath: sourcePath, styles: styles)
    parserError = nil

    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      let message =
        parserError?.localizedDescription
        ?? parser.parserError?.localizedDescription
        ?? "Unknown XML parser error."
      throw ASKHWPError.xmlParsingFailed("\(sourcePath): \(message)")
    }
    return accumulator.result()
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
    accumulator.reduce(.startElement(name: elementName, attributes: attributeDict))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    accumulator.reduce(.characters(string))
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    accumulator.reduce(.endElement(name: elementName))
  }
}
