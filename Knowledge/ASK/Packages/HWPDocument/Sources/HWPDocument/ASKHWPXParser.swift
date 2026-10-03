import Foundation
import DocumentCore

#if canImport(FoundationXML)
  import FoundationXML
#endif

public struct ASKHWPXParser: Sendable {
  public let limits: ASKHWPParserLimits

  public init(limits: ASKHWPParserLimits = .default) {
    self.limits = limits
  }

  public func parse(data: Data) throws -> ASKHWPDocument {
    try limits.validateInputSize(data.count)
    let archive = try ASKZIPArchive(data: data, limits: limits)
    let manifest = try Self.readManifest(from: archive)
    let sectionPaths = manifest?.sectionPaths.filter(archive.contains) ?? Self.sectionPaths(in: archive)
    guard !sectionPaths.isEmpty else {
      throw ASKHWPError.malformedDocument("HWPX package has no Contents/section*.xml entries.")
    }
    guard sectionPaths.count <= limits.maximumEntryOrSectionCount else {
      throw ASKHWPError.unsupportedFeature(
        "HWPX declares \(sectionPaths.count) sections, above the configured \(limits.maximumEntryOrSectionCount) section limit."
      )
    }

    var metadata = try Self.readMetadata(from: archive)
    metadata["container"] = "zip"
    metadata["sectionCount"] = String(sectionPaths.count)
    let binaryObjects = try Self.readBinaryObjects(from: archive)
    metadata["binaryObjectCount"] = String(binaryObjects.count)
    metadata["manifestSectionOrder"] = manifest == nil ? "fallback" : "spine"

    let styles: ASKHWPXStyleCatalog
    if let headerPath = manifest?.headerPath, archive.contains(headerPath) {
      styles = try ASKHWPXStyleCatalog(data: archive.data(for: headerPath))
    } else if archive.contains("Contents/header.xml") {
      styles = try ASKHWPXStyleCatalog(data: archive.data(for: "Contents/header.xml"))
    } else {
      styles = .empty
    }
    metadata["charStyleCount"] = String(styles.charStyleCount)
    metadata["paragraphStyleCount"] = String(styles.paragraphStyleCount)

    var sections: [ASKHWPSection] = []
    for (index, path) in sectionPaths.enumerated() {
      let xmlData = try archive.data(for: path)
      let parsedSection = try ASKHWPXSectionXMLParser(sourcePath: path, styles: styles).parse(data: xmlData)
      sections.append(
        .init(
          index: index,
          title: nil,
          sourcePath: path,
          pageMetrics: parsedSection.pageMetrics,
          paragraphs: parsedSection.paragraphs,
          contentBlocks: parsedSection.contentBlocks
        ))
    }

    let title =
      metadata["title"]?.nonEmptyValue ?? ASKHWPParserSupport.fallbackTitle(from: sections)
      ?? "Untitled HWPX"
    return ASKHWPDocument(
      format: .hwpx, title: title, sections: sections, metadata: metadata,
      binaryObjects: binaryObjects)
  }

  private static func readManifest(from archive: ASKZIPArchive) throws -> ASKHWPXPackageManifest? {
    guard archive.contains("Contents/content.hpf") else { return nil }
    return try ASKHWPXPackageManifest(data: archive.data(for: "Contents/content.hpf"))
  }

  private static func sectionPaths(in archive: ASKZIPArchive) -> [String] {
    archive.entryPaths()
      .filter { path in
        guard path.hasPrefix("Contents/"), path.hasSuffix(".xml") else { return false }
        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return fileName.hasPrefix("section")
      }
      .sorted { lhs, rhs in
        ASKHWPParserSupport.sectionIndex(from: lhs) < ASKHWPParserSupport.sectionIndex(from: rhs)
      }
  }

  private static func readMetadata(from archive: ASKZIPArchive) throws -> [String: String] {
    var metadata: [String: String] = [:]
    for path in ["Contents/content.hpf", "Contents/header.xml", "version.xml"]
    where archive.contains(path) {
      let data = try archive.data(for: path)
      let extracted = try ASKHWPXMetadataXMLParser().parse(data: data)
      for (key, value) in extracted where metadata[key] == nil {
        metadata[key] = value
      }
    }
    return metadata
  }

  private static func readBinaryObjects(from archive: ASKZIPArchive) throws -> [String:
    ASKHWPBinaryObject]
  {
    var objects: [String: ASKHWPBinaryObject] = [:]
    for path in archive.entryPaths() where isBinaryOrExternalObject(path) {
      let data = try archive.data(for: path)
      let fileName = URL(fileURLWithPath: path).lastPathComponent
      let object = ASKHWPBinaryObject(
        id: fileName, path: path, mediaType: mediaType(for: path), data: data)
      objects[path] = object
    }
    return objects
  }

  private static func isBinaryOrExternalObject(_ path: String) -> Bool {
    guard !path.hasSuffix("/") else { return false }
    return path.hasPrefix("BinData/") || path.hasPrefix("Chart/")
  }

  private static func mediaType(for path: String) -> String? {
    if path.hasPrefix("Chart/"), path.hasSuffix(".xml") {
      return "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    }
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "bmp": return "image/bmp"
    case "svg": return "image/svg+xml"
    case "webp": return "image/webp"
    case "xml": return "application/xml"
    default: return nil
    }
  }

}
