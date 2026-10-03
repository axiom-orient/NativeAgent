import DocumentCore
import Foundation

struct ASKHWPMediaLayoutEngine: Sendable {
  func layout(
    image: ASKHWPImage,
    binaryObjectIndex: ASKHWPBinaryObjectIndex,
    sectionIndex: Int,
    metrics: ASKHWPPageMetrics,
    pageFlow: inout ASKHWPPageFlowState
  ) throws {
    guard var current = pageFlow.current else {
      throw ASKHWPError.malformedDocument("Internal image layout state was not initialized.")
    }
    let size = fittedSize(
      width: image.width ?? min(metrics.contentWidth, 180), height: image.height ?? 120,
      maxWidth: metrics.contentWidth)
    if current.cursorY + size.height > current.pageBottom, !current.isEmpty {
      current = pageFlow.breakPage(
        committing: current,
        sectionIndex: sectionIndex,
        metrics: metrics,
        includeEmptyCurrent: false
      )
    }
    let frame = ASKCanvasRect(
      x: metrics.contentX, y: current.cursorY, width: size.width, height: size.height)
    current.imageFragments.append(
      ASKHWPRenderedImageFragment(
        id: image.id,
        sectionIndex: sectionIndex,
        image: image,
        frame: frame,
        binaryObject: binaryObjectIndex.resolve(image)
      ))
    current.cursorY += size.height + 8
    pageFlow.current = current
  }

  func layout(
    object: ASKHWPDrawObject,
    sectionIndex: Int,
    metrics: ASKHWPPageMetrics,
    pageFlow: inout ASKHWPPageFlowState
  ) throws {
    guard var current = pageFlow.current else {
      throw ASKHWPError.malformedDocument("Internal object layout state was not initialized.")
    }
    let size = fittedSize(
      width: object.width ?? min(metrics.contentWidth, 160), height: object.height ?? 96,
      maxWidth: metrics.contentWidth)
    let advancesCursor = shouldAdvanceCursor(for: object)
    if advancesCursor, current.cursorY + size.height > current.pageBottom, !current.isEmpty {
      current = pageFlow.breakPage(
        committing: current,
        sectionIndex: sectionIndex,
        metrics: metrics,
        includeEmptyCurrent: false
      )
    }
    let frame = frame(for: object, size: size, metrics: metrics, cursorY: current.cursorY)
    current.objectFragments.append(
      ASKHWPRenderedObjectFragment(
        id: object.id, sectionIndex: sectionIndex, object: object, frame: frame))
    if advancesCursor {
      current.cursorY = max(current.cursorY, frame.origin.y + size.height) + 8
    }
    pageFlow.current = current
  }

  private func frame(
    for object: ASKHWPDrawObject,
    size: (width: Double, height: Double),
    metrics: ASKHWPPageMetrics,
    cursorY: Double
  ) -> ASKCanvasRect {
    let placement = object.placement
    let relativeToPageX =
      placement.horzRelTo?.uppercased() == "PAPER" || placement.horzRelTo?.uppercased() == "PAGE"
    let relativeToPageY =
      placement.vertRelTo?.uppercased() == "PAPER" || placement.vertRelTo?.uppercased() == "PAGE"
    let baseX = relativeToPageX ? 0 : metrics.contentX
    let baseY = relativeToPageY ? 0 : cursorY
    let x = min(max(baseX + placement.horzOffset, 0), max(metrics.width - size.width, 0))
    let y = min(
      max(baseY + placement.vertOffset, 0),
      max(metrics.height - metrics.marginBottom - size.height, 0))
    return ASKCanvasRect(x: x, y: y, width: size.width, height: size.height)
  }

  private func shouldAdvanceCursor(for object: ASKHWPDrawObject) -> Bool {
    if object.placement.treatAsChar { return true }
    switch object.placement.textWrap?.uppercased() {
    case "IN_FRONT_OF_TEXT", "BEHIND_TEXT":
      return false
    case "TOP_AND_BOTTOM":
      return true
    default:
      return object.placement.flowWithText
    }
  }

  private func fittedSize(width: Double, height: Double, maxWidth: Double) -> (
    width: Double, height: Double
  ) {
    let safeWidth = max(width, 1)
    let safeHeight = max(height, 1)
    guard safeWidth > maxWidth else { return (safeWidth, safeHeight) }
    let scale = maxWidth / safeWidth
    return (maxWidth, safeHeight * scale)
  }

}

struct ASKHWPBinaryObjectIndex: Sendable, Hashable {
  private let objectsByKey: [String: ASKHWPBinaryObject]

  init(binaryObjects: [String: ASKHWPBinaryObject]) {
    var indexed = binaryObjects
    for object in binaryObjects.values {
      for key in Self.keys(for: object) where indexed[key] == nil {
        indexed[key] = object
      }
    }
    self.objectsByKey = indexed
  }

  func resolve(_ image: ASKHWPImage) -> ASKHWPBinaryObject? {
    let candidates = [
      image.binaryPath,
      image.referenceID,
      image.binaryPath.map { "BinData/\($0)" },
      image.referenceID.map { "BinData/\($0)" },
    ].compactMap { $0 }
    for candidate in candidates {
      for key in Self.keys(forCandidate: candidate) {
        if let object = objectsByKey[key] {
          return object
        }
      }
    }
    return nil
  }

  private static func keys(for object: ASKHWPBinaryObject) -> [String] {
    keys(forCandidate: object.path) + keys(forCandidate: object.id)
  }

  private static func keys(forCandidate candidate: String) -> [String] {
    let url = URL(fileURLWithPath: candidate)
    let fileName = url.lastPathComponent
    let stem = url.deletingPathExtension().lastPathComponent
    return [candidate, fileName, stem]
  }
}
