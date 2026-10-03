struct ASKHWPXSectionAccumulator: Sendable, Hashable {
  private let sourcePath: String
  private let styles: ASKHWPXStyleCatalog
  private var paragraphs: [ASKHWPParagraph] = []
  private var contentBlocks: [ASKHWPContentBlock] = []
  private var depth = 0
  private var pageMetrics = ASKHWPXPageMetricsAccumulator()
  private var paragraph = ASKHWPXParagraphAccumulator()
  private var table: ASKHWPXTableAccumulator
  private var image = ASKHWPXImageAccumulator()
  private var drawObject = ASKHWPXDrawObjectAccumulator()

  init(sourcePath: String, styles: ASKHWPXStyleCatalog = .empty) {
    self.sourcePath = sourcePath
    self.styles = styles
    self.table = ASKHWPXTableAccumulator(sourcePath: sourcePath, styles: styles)
  }

  mutating func reduce(_ event: ASKHWPXSectionEvent) {
    switch event {
    case .startElement(let name, let rawAttributes):
      startElement(name: name, rawAttributes: rawAttributes)
    case .characters(let characters):
      appendCharacters(characters)
    case .endElement(let name):
      endElement(name: name)
    }
  }

  func result() -> ASKHWPXParsedSection {
    ASKHWPXParsedSection(
      pageMetrics: pageMetrics.makeMetrics(),
      paragraphs: paragraphs,
      contentBlocks: contentBlocks
    )
  }

  private mutating func startElement(
    name: String,
    rawAttributes: [String: String]
  ) {
    depth += 1
    let localName = xmlLocalName(name).lowercased()
    let attributes = AttributeLookup(rawAttributes)

    switch localName {
    case "pagepr":
      pageMetrics.capturePageProperties(attributes)
    case "margin":
      pageMetrics.captureMargin(attributes)
    default:
      break
    }

    if table.consumeStart(
      localName: localName,
      depth: depth,
      attributes: attributes,
      completedBlockCount: contentBlocks.count
    ) {
      return
    }

    if image.consumeStart(
      localName: localName,
      depth: depth,
      attributes: attributes,
      sourcePath: sourcePath,
      completedBlockCount: contentBlocks.count
    ) {
      return
    }

    if drawObject.consumeStart(
      localName: localName,
      depth: depth,
      attributes: attributes,
      sourcePath: sourcePath,
      completedBlockCount: contentBlocks.count
    ) {
      return
    }

    if paragraph.beginIfNeeded(localName: localName, depth: depth, attributes: attributes) {
      return
    }
    paragraph.startElement(localName: localName, depth: depth, attributes: attributes)
  }

  private mutating func appendCharacters(_ characters: String) {
    if table.consumeCharacters(characters) { return }
    if drawObject.consumeCharacters(characters) { return }
    if image.consumeCharacters(characters) { return }
    paragraph.appendCharacters(characters)
  }

  private mutating func endElement(name: String) {
    let localName = xmlLocalName(name).lowercased()

    if table.isActive {
      if let completed = table.consumeEnd(localName: localName, depth: depth) {
        contentBlocks.append(.table(completed))
      }
      depth -= 1
      return
    }

    if image.isActive {
      if let completed = image.consumeEnd(localName: localName, depth: depth) {
        contentBlocks.append(.image(completed))
      }
      depth -= 1
      return
    }

    if drawObject.isActive {
      if let completed = drawObject.consumeEnd(localName: localName, depth: depth) {
        contentBlocks.append(.drawObject(completed))
      }
      depth -= 1
      return
    }

    if let completed = paragraph.endElement(
      localName: localName,
      depth: depth,
      sourcePath: sourcePath,
      paragraphIndex: paragraphs.count
    ) {
      let resolved = styles.resolve(paragraph: completed)
      paragraphs.append(resolved)
      contentBlocks.append(.paragraph(resolved))
    }
    depth -= 1
  }
}
