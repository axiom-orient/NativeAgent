import DocumentCore
import Foundation

public struct ASKHWPPageLayoutRenderer: Sendable {
  public let configuration: ASKHWPLayoutConfiguration
  private let textLayout: ASKHWPTextLayoutEngine
  private let tableLayout: ASKHWPTableLayoutEngine
  private let mediaLayout: ASKHWPMediaLayoutEngine

  public init(
    configuration: ASKHWPLayoutConfiguration = .init(),
    measurer: ASKHWPTextMeasurer = .init()
  ) {
    self.configuration = configuration
    let textLayout = ASKHWPTextLayoutEngine(configuration: configuration, measurer: measurer)
    self.textLayout = textLayout
    self.tableLayout = ASKHWPTableLayoutEngine(textLayout: textLayout)
    self.mediaLayout = ASKHWPMediaLayoutEngine()
  }

  public func render(_ document: ASKHWPDocument) throws -> ASKHWPRenderedDocument {
    var pageFlow = ASKHWPPageFlowState()
    let binaryObjectIndex = ASKHWPBinaryObjectIndex(binaryObjects: document.binaryObjects)

    for section in document.sections {
      let metrics = section.pageMetrics ?? configuration.defaultPageMetrics
      try validate(metrics: metrics, sectionIndex: section.index)

      pageFlow.apply(.beginSection(sectionIndex: section.index, metrics: metrics))

      for block in section.contentBlocks {
        switch block {
        case .paragraph(let paragraph):
          try textLayout.layout(
            paragraph: paragraph, sectionIndex: section.index, metrics: metrics,
            pageFlow: &pageFlow)
        case .table(let table):
          try tableLayout.layout(
            table: table, sectionIndex: section.index, metrics: metrics,
            pageFlow: &pageFlow)
        case .image(let image):
          try mediaLayout.layout(
            image: image, binaryObjectIndex: binaryObjectIndex, sectionIndex: section.index,
            metrics: metrics, pageFlow: &pageFlow)
        case .drawObject(let object):
          try mediaLayout.layout(
            object: object, sectionIndex: section.index, metrics: metrics,
            pageFlow: &pageFlow)
        }
      }
    }

    pageFlow.apply(.finishDocument)

    return ASKHWPRenderedDocument(
      title: document.title, format: document.format, pages: pageFlow.pages,
      metadata: document.metadata,
      binaryObjects: document.binaryObjects)
  }

  private func validate(metrics: ASKHWPPageMetrics, sectionIndex: Int) throws {
    guard metrics.contentWidth >= configuration.minRenderableLineWidth else {
      throw ASKHWPError.malformedDocument(
        "Section \(sectionIndex) page content width is too small for layout: \(metrics.contentWidth)."
      )
    }
    guard metrics.contentHeight > 0 else {
      throw ASKHWPError.malformedDocument(
        "Section \(sectionIndex) page content height is not positive.")
    }
  }

}
