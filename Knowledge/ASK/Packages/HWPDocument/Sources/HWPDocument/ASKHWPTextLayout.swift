import DocumentCore
import Foundation
#if canImport(CoreText)
import CoreText
#endif

public struct ASKHWPTextMeasurer: Sendable, Hashable, Codable {
  public init() {}

  public func width(
    of text: String,
    attributes: ASKHWPTextAttributes,
    paragraphStyle: ASKHWPParagraphStyle
  ) -> Double {
    let pointSize = attributes.pointSize ?? paragraphStyle.basePointSize
    #if canImport(CoreText)
    guard pointSize > 0, !text.isEmpty else { return 0 }
    guard let systemFont = CTFontCreateUIFontForLanguage(.system, pointSize, nil) else {
      preconditionFailure("CoreText cannot create the system font for a positive point size.")
    }
    var traits: CTFontSymbolicTraits = []
    if attributes.isBold { traits.insert(.boldTrait) }
    if attributes.isItalic { traits.insert(.italicTrait) }
    let font: CTFont
    if traits.isEmpty {
      font = systemFont
    } else {
      guard let styledFont = CTFontCreateCopyWithSymbolicTraits(systemFont, pointSize, nil, traits, traits) else {
        preconditionFailure("CoreText system font cannot provide requested bold/italic traits.")
      }
      font = styledFont
    }
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attributed)
    // The native view proposes an exact width to Text. Round upward so subpixel
    // layout does not make a correctly measured line truncate with an ellipsis.
    return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    #else
    let emphasisMultiplier = (attributes.isBold ? 1.04 : 1.0) * (attributes.isItalic ? 1.01 : 1.0)
    return text.unicodeScalars.reduce(0) { partial, scalar in
      partial + advance(for: scalar, pointSize: pointSize) * emphasisMultiplier
    }
    #endif
  }

  public func advance(for scalar: UnicodeScalar, pointSize: Double) -> Double {
    switch scalar.value {
    case 0x0009:
      return pointSize * 2
    case 0x0020, 0x00A0:
      return pointSize * 0.33
    case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE10...0xFE19,
      0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
      return pointSize
    default:
      return pointSize * 0.56
    }
  }
}

public struct ASKHWPResponsivePageFit: Sendable, Hashable, Codable {
  public let scale: Double
  public let fittedWidth: Double
  public let fittedHeight: Double

  public init(scale: Double, fittedWidth: Double, fittedHeight: Double) {
    self.scale = scale
    self.fittedWidth = fittedWidth
    self.fittedHeight = fittedHeight
  }
}

public struct ASKHWPResponsivePageFitter: Sendable, Hashable, Codable {
  public let minScale: Double
  public let maxScale: Double
  public let horizontalPadding: Double

  public init(minScale: Double = 0.2, maxScale: Double = 2.0, horizontalPadding: Double = 24) {
    self.minScale = max(minScale, 0.01)
    self.maxScale = max(maxScale, self.minScale)
    self.horizontalPadding = max(horizontalPadding, 0)
  }

  public func fit(pageMetrics: ASKHWPPageMetrics, viewportWidth: Double) -> ASKHWPResponsivePageFit
  {
    let availableWidth = max(viewportWidth - horizontalPadding * 2, 1)
    let rawScale = availableWidth / pageMetrics.width
    let clampedScale = min(max(rawScale, minScale), maxScale)
    let scale = min(clampedScale, rawScale)
    return ASKHWPResponsivePageFit(
      scale: scale,
      fittedWidth: pageMetrics.width * scale,
      fittedHeight: pageMetrics.height * scale
    )
  }
}

struct ASKHWPTextLayoutEngine: Sendable {
  let configuration: ASKHWPLayoutConfiguration
  let measurer: ASKHWPTextMeasurer

  func layout(
    paragraph: ASKHWPParagraph,
    sectionIndex: Int,
    metrics: ASKHWPPageMetrics,
    pageFlow: inout ASKHWPPageFlowState
  ) throws {
    let style = paragraph.style
    let paragraphText = paragraph.plainText
    guard !paragraphText.isEmpty else { return }

    let lineHeight = style.lineHeight
    guard lineHeight > 0, lineHeight <= metrics.contentHeight else {
      throw ASKHWPError.malformedDocument(
        "Paragraph \(paragraph.index) line height cannot fit the page content height.")
    }

    guard var current = pageFlow.current else {
      throw ASKHWPError.malformedDocument("Internal layout state was not initialized.")
    }

    if current.cursorY + style.spacingBefore + lineHeight > current.pageBottom {
      current = pageFlow.breakPage(
        committing: current,
        sectionIndex: sectionIndex,
        metrics: metrics,
        includeEmptyCurrent: true
      )
    } else {
      current.cursorY += style.spacingBefore
    }

    let lines = breakLines(paragraph: paragraph, metrics: metrics)
    let sourceSegments = runSegments(for: paragraph)

    for line in lines {
      if current.cursorY + lineHeight > current.pageBottom {
        current = pageFlow.breakPage(
          committing: current,
          sectionIndex: sectionIndex,
          metrics: metrics,
          includeEmptyCurrent: true
        )
      }

      let x = alignedX(for: line, style: style, metrics: metrics)
      let fragments = makeFragments(
        line: line,
        paragraph: paragraph,
        sectionIndex: sectionIndex,
        baselineX: x,
        baselineY: current.cursorY + line.baselineOffset,
        lineHeight: lineHeight,
        sourceSegments: sourceSegments
      )
      current.bodyTextFragments.append(contentsOf: fragments)
      current.cursorY += lineHeight
    }

    current.cursorY += style.spacingAfter
    pageFlow.current = current
  }
  func breakLines(
    paragraph: ASKHWPParagraph,
    metrics: ASKHWPPageMetrics
  ) -> [ASKHWPLaidOutParagraphLine] {
    ASKHWPParagraphLineBreaker(
      paragraph: paragraph,
      metrics: metrics,
      measurer: measurer,
      configuration: configuration
    ).breakLines()
  }

  func alignedX(
    for line: ASKHWPLaidOutParagraphLine,
    style: ASKHWPParagraphStyle,
    metrics: ASKHWPPageMetrics
  ) -> Double {
    let contentLeft =
      metrics.contentX + style.leftIndent + (line.isFirstVisualLine ? style.firstLineIndent : 0)
    let contentWidth = max(
      metrics.contentWidth - style.leftIndent - style.rightIndent
        - (line.isFirstVisualLine ? max(style.firstLineIndent, 0) : 0),
      configuration.minRenderableLineWidth
    )
    switch style.alignment {
    case .left, .justified:
      return contentLeft
    case .center:
      return contentLeft + max((contentWidth - line.width) / 2, 0)
    case .right:
      return contentLeft + max(contentWidth - line.width, 0)
    }
  }

  func makeFragments(
    line: ASKHWPLaidOutParagraphLine,
    paragraph: ASKHWPParagraph,
    sectionIndex: Int,
    baselineX: Double,
    baselineY: Double,
    lineHeight: Double,
    sourceSegments: [ASKHWPTextRunSegment]
  ) -> [ASKHWPRenderedTextFragment] {
    var fragments: [ASKHWPRenderedTextFragment] = []
    var cursorX = baselineX

    for segment in sourceSegments {
      guard let overlap = segment.range.intersection(line.range) else { continue }
      let localStart = overlap.start - segment.range.start
      let localEnd = overlap.end - segment.range.start
      let text = segment.run.text.askHWPSubstring(start: localStart, end: localEnd)
      guard !text.isEmpty else { continue }
      let width = measurer.width(
        of: text,
        attributes: segment.run.attributes,
        paragraphStyle: paragraph.style
      )
      let frame = ASKCanvasRect(
        x: cursorX,
        y: baselineY - line.baselineOffset,
        width: width,
        height: lineHeight
      )
      fragments.append(
        ASKHWPRenderedTextFragment(
          sectionIndex: sectionIndex,
          paragraphIndex: paragraph.index,
          runIndex: segment.runIndex,
          text: text,
          frame: frame,
          baselineY: baselineY,
          attributes: segment.run.attributes,
          paragraphStyle: paragraph.style,
          sourcePath: paragraph.sourcePath,
          sourceRange: overlap
        )
      )
      cursorX += width
    }

    return fragments
  }

  func layoutParagraphsInCell(
    _ paragraphs: [ASKHWPParagraph],
    cellFrame: ASKCanvasRect,
    padding: Double,
    sectionIndex: Int
  ) -> [ASKHWPRenderedTextFragment] {
    let metrics = ASKHWPPageMetrics(
      width: cellFrame.size.width,
      height: cellFrame.size.height,
      marginTop: padding,
      marginRight: padding,
      marginBottom: padding,
      marginLeft: padding
    )
    var fragments: [ASKHWPRenderedTextFragment] = []
    var cursorY = cellFrame.origin.y + padding
    let pageBottom = cellFrame.origin.y + cellFrame.size.height - padding

    for paragraph in paragraphs {
      let lineHeight = paragraph.style.lineHeight
      let lines = breakLines(paragraph: paragraph, metrics: metrics)
      let sourceSegments = runSegments(for: paragraph)
      // Repeated non-integral line heights can exceed their exact sum by a few ulps.
      for line in lines where cursorY + lineHeight <= pageBottom + 1e-9 {
        let localX = alignedX(for: line, style: paragraph.style, metrics: metrics)
        fragments.append(
          contentsOf: makeFragments(
            line: line,
            paragraph: paragraph,
            sectionIndex: sectionIndex,
            baselineX: cellFrame.origin.x + localX,
            baselineY: cursorY + line.baselineOffset,
            lineHeight: lineHeight,
            sourceSegments: sourceSegments
          )
        )
        cursorY += lineHeight
      }
      cursorY += paragraph.style.spacingAfter
    }

    return fragments
  }

  func runSegments(for paragraph: ASKHWPParagraph) -> [ASKHWPTextRunSegment] {
    var segments: [ASKHWPTextRunSegment] = []
    var offset = 0
    for (index, run) in paragraph.runs.enumerated() {
      let start = offset
      let end = start + run.text.count
      segments.append(
        .init(
          runIndex: index,
          run: run,
          range: ASKPageSourceRange(start: start, end: end)
        )
      )
      offset = end
    }
    return segments
  }
}

struct ASKHWPLaidOutParagraphLine: Sendable, Hashable {
  let range: ASKPageSourceRange
  let width: Double
  let baselineOffset: Double
  let isFirstVisualLine: Bool
}

private struct ASKHWPParagraphLineBreaker: Sendable {
  let paragraph: ASKHWPParagraph
  let metrics: ASKHWPPageMetrics
  let measurer: ASKHWPTextMeasurer
  let configuration: ASKHWPLayoutConfiguration

  func breakLines() -> [ASKHWPLaidOutParagraphLine] {
    let text = paragraph.plainText
    let characters = Array(text)
    guard !characters.isEmpty else { return [] }

    var lines: [ASKHWPLaidOutParagraphLine] = []
    var offset = 0
    var isFirstVisualLine = true
    let runSegments = ASKHWPTextLayoutEngine(
      configuration: configuration,
      measurer: measurer
    ).runSegments(for: paragraph)

    while offset < characters.count {
      let line = nextLine(
        characters: characters,
        start: offset,
        isFirstVisualLine: isFirstVisualLine,
        runSegments: runSegments
      )
      lines.append(line)
      offset = nextOffset(after: line, characters: characters)
      isFirstVisualLine = false
    }
    return lines
  }

  private func nextLine(
    characters: [Character],
    start: Int,
    isFirstVisualLine: Bool,
    runSegments: [ASKHWPTextRunSegment]
  ) -> ASKHWPLaidOutParagraphLine {
    let style = paragraph.style
    let firstLineIndent = isFirstVisualLine ? max(style.firstLineIndent, 0) : 0
    let maxWidth = max(
      metrics.contentWidth - style.leftIndent - style.rightIndent - firstLineIndent,
      configuration.minRenderableLineWidth
    )
    var width = 0.0
    var end = start
    var lastSoftBreak: Int?
    var lastSoftBreakWidth = 0.0

    while end < characters.count {
      let character = characters[end]
      if character == "\n" { break }
      let candidateWidth = measuredWidth(
        characters: characters, range: start..<(end + 1), segments: runSegments)
      if candidateWidth > maxWidth, end > start { break }
      width = candidateWidth
      end += 1
      if character == " " || character == "\t" || character == "-" || character == "/" {
        lastSoftBreak = end
        lastSoftBreakWidth = width
      }
    }

    if end < characters.count,
      characters[end] != "\n",
      let softBreak = lastSoftBreak,
      softBreak > start
    {
      end = softBreak
      width = lastSoftBreakWidth
      while end > start, characters[end - 1] == " " { end -= 1 }
      width = measuredWidth(characters: characters, range: start..<end, segments: runSegments)
    }

    if end == start {
      end = min(start + 1, characters.count)
      width = measuredWidth(characters: characters, range: start..<end, segments: runSegments)
    }

    return ASKHWPLaidOutParagraphLine(
      range: ASKPageSourceRange(start: start, end: end),
      width: width,
      baselineOffset: style.basePointSize * 1.05,
      isFirstVisualLine: isFirstVisualLine
    )
  }

  private func nextOffset(after line: ASKHWPLaidOutParagraphLine, characters: [Character]) -> Int {
    var offset = line.range.end
    if offset < characters.count, characters[offset] == "\n" { offset += 1 }
    while offset < characters.count, characters[offset] == " " { offset += 1 }
    return offset
  }

  private func attributesForCharacter(
    at offset: Int,
    segments: [ASKHWPTextRunSegment]
  ) -> ASKHWPTextAttributes {
    for segment in segments where segment.range.start <= offset && offset < segment.range.end {
      return segment.run.attributes
    }
    return .init()
  }

  private func measuredWidth(
    characters: [Character],
    range: Range<Int>,
    segments: [ASKHWPTextRunSegment]
  ) -> Double {
    guard range.lowerBound < range.upperBound else { return 0 }
    var width = 0.0
    for segment in segments {
      let lower = max(range.lowerBound, segment.range.start)
      let upper = min(range.upperBound, segment.range.end)
      guard lower < upper else { continue }
      width += measurer.width(
        of: String(characters[lower..<upper]),
        attributes: segment.run.attributes,
        paragraphStyle: paragraph.style
      )
    }
    return width
  }
}

struct ASKHWPTextRunSegment: Sendable, Hashable {
  let runIndex: Int
  let run: ASKHWPTextRun
  let range: ASKPageSourceRange
}

extension String {
  fileprivate func askHWPSubstring(start: Int, end: Int) -> String {
    guard start < end else { return "" }
    let characters = Array(self)
    guard start >= 0, end <= characters.count else { return "" }
    return String(characters[start..<end])
  }
}
