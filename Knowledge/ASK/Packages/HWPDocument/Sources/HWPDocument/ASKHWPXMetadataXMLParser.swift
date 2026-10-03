import Foundation
import DocumentCore

#if canImport(FoundationXML)
  import FoundationXML
#endif

final class ASKHWPXMetadataXMLParser: NSObject, XMLParserDelegate {
  private var metadata: [String: String] = [:]
  private var currentKey: String?
  private var currentText = ""
  private var parserError: Error?

  func parse(data: Data) throws -> [String: String] {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldProcessNamespaces = false
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      let message =
        parserError?.localizedDescription ?? parser.parserError?.localizedDescription
        ?? "Unknown XML parser error."
      throw ASKHWPError.xmlParsingFailed("metadata: \(message)")
    }
    return metadata
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
    switch localName {
    case "title", "subject", "creator", "created", "modified", "description", "keyword", "version":
      currentKey = localName
      currentText = ""
    default:
      currentKey = nil
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard currentKey != nil else { return }
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let currentKey else { return }
    let localName = xmlLocalName(elementName).lowercased()
    guard localName == currentKey else { return }
    let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty, metadata[currentKey] == nil {
      metadata[currentKey] = value
    }
    self.currentKey = nil
    currentText = ""
  }
}
