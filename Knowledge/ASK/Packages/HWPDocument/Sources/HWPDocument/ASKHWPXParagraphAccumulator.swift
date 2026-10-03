struct ASKHWPXParagraphAccumulator: Sendable, Hashable {
  private var runs: [ASKHWPTextRun] = []
  private var text = ""
  private var paragraphDepth: Int?
  private var textDepth = 0
  private var runDepth: Int?
  private var style = ASKHWPParagraphStyle.body
  private var runAttributes = ASKHWPTextAttributes()
  private var textAttributes = ASKHWPTextAttributes()

  var isActive: Bool { paragraphDepth != nil }

  mutating func beginIfNeeded(
    localName: String,
    depth: Int,
    attributes: AttributeLookup
  ) -> Bool {
    guard localName == "p", paragraphDepth == nil else { return false }
    paragraphDepth = depth
    runs = []
    text = ""
    style = ASKHWPXAttributeDecoder.paragraphStyle(from: attributes)
    runAttributes = ASKHWPTextAttributes(
      styleID: attributes.string(["styleIDRef", "styleIdRef", "styleID", "styleId"]),
      charShapeID: nil
    )
    textAttributes = runAttributes
    return true
  }

  mutating func startElement(
    localName: String,
    depth: Int,
    attributes: AttributeLookup
  ) {
    guard isActive else { return }
    switch localName {
    case "run", "r":
      flushTextIfNeeded()
      runDepth = depth
      runAttributes = runAttributes.merged(
        overriding: ASKHWPXAttributeDecoder.textAttributes(from: attributes))
    case "t", "text":
      flushTextIfNeeded()
      textDepth += 1
      textAttributes = runAttributes.merged(
        overriding: ASKHWPXAttributeDecoder.textAttributes(from: attributes))
    case "linebreak", "linebreakforlatin", "br":
      appendSyntheticText("\n")
    case "tab":
      appendSyntheticText("\t")
    case "nbspace":
      appendSyntheticText("\u{00A0}")
    case "fwspace":
      appendSyntheticText("\u{3000}")
    case "hyphen":
      appendSyntheticText("-")
    default:
      break
    }
  }

  mutating func appendCharacters(_ characters: String) {
    guard isActive, textDepth > 0 else { return }
    text += characters
  }

  mutating func endElement(
    localName: String,
    depth: Int,
    sourcePath: String,
    paragraphIndex: Int
  ) -> ASKHWPParagraph? {
    guard isActive else { return nil }

    if localName == "t" || localName == "text" {
      flushTextIfNeeded()
      textDepth = max(textDepth - 1, 0)
      textAttributes = runAttributes
    }

    if let runDepth, depth == runDepth, localName == "run" || localName == "r" {
      flushTextIfNeeded()
      self.runDepth = nil
      runAttributes = ASKHWPTextAttributes(styleID: style.styleID, charShapeID: nil)
    }

    guard let paragraphDepth, depth == paragraphDepth, localName == "p" else {
      return nil
    }

    flushTextIfNeeded()
    let visibleText = runs.map(\.text).joined()
    let result: ASKHWPParagraph?
    if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result = nil
    } else {
      result = ASKHWPParagraph(
        index: paragraphIndex,
        runs: runs,
        sourcePath: sourcePath,
        style: style
      )
    }
    reset()
    return result
  }

  private mutating func appendSyntheticText(_ value: String) {
    flushTextIfNeeded()
    runs.append(ASKHWPTextRun(text: value, attributes: runAttributes))
  }

  private mutating func flushTextIfNeeded() {
    guard !text.isEmpty else { return }
    runs.append(ASKHWPTextRun(text: text, attributes: textAttributes))
    text = ""
  }

  private mutating func reset() {
    runs = []
    text = ""
    paragraphDepth = nil
    textDepth = 0
    runDepth = nil
    style = .body
    runAttributes = .init()
    textAttributes = .init()
  }
}
