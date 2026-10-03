import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

struct ASKHWPXPackageManifest: Sendable, Hashable {
  let sectionPaths: [String]
  let headerPath: String?

  init(data: Data) throws {
    let parser = ASKHWPXPackageManifestXMLParser(data: data)
    let parsed = try parser.parse()
    self.sectionPaths = parsed.sectionPaths
    self.headerPath = parsed.headerPath
  }
}

private final class ASKHWPXPackageManifestXMLParser: NSObject, XMLParserDelegate {
  private let data: Data
  private var items: [String: String] = [:]
  private var spineIDs: [String] = []
  private var parserError: Error?

  init(data: Data) {
    self.data = data
  }

  func parse() throws -> (sectionPaths: [String], headerPath: String?) {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      throw ASKHWPError.xmlParsingFailed(
        "Contents/content.hpf: \(parserError?.localizedDescription ?? parser.parserError?.localizedDescription ?? "Unknown XML parser error.")"
      )
    }

    let paths = spineIDs.compactMap { items[$0] }.map(Self.normalizePath)
    let sectionPaths = paths.filter { path in
      let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
      return fileName.hasPrefix("section") && fileName.hasSuffix(".xml")
    }
    let headerPath = paths.first { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "header.xml" }
    return (sectionPaths, headerPath)
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
    switch xmlLocalName(elementName).lowercased() {
    case "item":
      let attributes = AttributeLookup(attributeDict)
      if let id = attributes.string(["id"]), let href = attributes.string(["href"]) {
        items[id] = href
      }
    case "itemref":
      if let id = AttributeLookup(attributeDict).string(["idref"]) {
        spineIDs.append(id)
      }
    default:
      break
    }
  }

  private static func normalizePath(_ rawPath: String) -> String {
    let path = rawPath.removingPercentEncoding ?? rawPath
    if path.hasPrefix("Contents/") || path.hasPrefix("BinData/") || path.hasPrefix("Chart/") {
      return path
    }
    let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    if fileName.hasPrefix("section") || fileName == "header.xml" {
      return "Contents/\(path)"
    }
    return path
  }
}
