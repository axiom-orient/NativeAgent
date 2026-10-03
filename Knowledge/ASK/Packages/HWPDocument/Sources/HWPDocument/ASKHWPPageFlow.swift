import DocumentCore

/// Explicit page lifecycle events. Fragment calculation remains in dedicated pure layout engines.
enum ASKHWPPageFlowEvent: Sendable, Hashable {
  case beginSection(sectionIndex: Int, metrics: ASKHWPPageMetrics)
  case breakPage(sectionIndex: Int, metrics: ASKHWPPageMetrics, includeEmptyCurrent: Bool)
  case finishDocument
}

struct ASKHWPPageFlowState: Sendable, Hashable {
  var pages: [ASKHWPRenderedPage] = []
  var current: ASKHWPPageBuilder?

  mutating func apply(_ event: ASKHWPPageFlowEvent) {
    self = ASKHWPPageFlowReducer.reduce(state: self, event: event)
  }

  mutating func breakPage(
    committing page: ASKHWPPageBuilder,
    sectionIndex: Int,
    metrics: ASKHWPPageMetrics,
    includeEmptyCurrent: Bool
  ) -> ASKHWPPageBuilder {
    current = page
    apply(
      .breakPage(
        sectionIndex: sectionIndex,
        metrics: metrics,
        includeEmptyCurrent: includeEmptyCurrent
      )
    )
    return current
      ?? ASKHWPPageBuilder(
        index: pages.count,
        sectionIndex: sectionIndex,
        metrics: metrics
      )
  }
}

enum ASKHWPPageFlowReducer {
  static func reduce(
    state: ASKHWPPageFlowState,
    event: ASKHWPPageFlowEvent
  ) -> ASKHWPPageFlowState {
    var next = state

    switch event {
    case .beginSection(let sectionIndex, let metrics):
      guard next.current == nil || next.current?.metrics != metrics else { return next }
      if let completed = next.current?.finish(), !completed.isEmpty {
        next.pages.append(completed)
      }
      next.current = ASKHWPPageBuilder(
        index: next.pages.count,
        sectionIndex: sectionIndex,
        metrics: metrics
      )

    case .breakPage(let sectionIndex, let metrics, let includeEmptyCurrent):
      if let completed = next.current?.finish(), includeEmptyCurrent || !completed.isEmpty {
        next.pages.append(completed)
      }
      next.current = ASKHWPPageBuilder(
        index: next.pages.count,
        sectionIndex: sectionIndex,
        metrics: metrics
      )

    case .finishDocument:
      if let completed = next.current?.finish(), !completed.isEmpty || next.pages.isEmpty {
        next.pages.append(completed)
      }
      next.current = nil
    }

    return next
  }
}

struct ASKHWPPageBuilder: Sendable, Hashable {
  let index: Int
  let sectionIndex: Int
  let metrics: ASKHWPPageMetrics
  var cursorY: Double
  var bodyTextFragments: [ASKHWPRenderedTextFragment]
  var tableFragments: [ASKHWPRenderedTableFragment]
  var imageFragments: [ASKHWPRenderedImageFragment]
  var objectFragments: [ASKHWPRenderedObjectFragment]

  init(index: Int, sectionIndex: Int, metrics: ASKHWPPageMetrics) {
    self.index = index
    self.sectionIndex = sectionIndex
    self.metrics = metrics
    self.cursorY = metrics.contentY
    self.bodyTextFragments = []
    self.tableFragments = []
    self.imageFragments = []
    self.objectFragments = []
  }

  var pageBottom: Double { metrics.height - metrics.marginBottom }

  var isEmpty: Bool {
    bodyTextFragments.isEmpty && tableFragments.isEmpty && imageFragments.isEmpty
      && objectFragments.isEmpty
  }

  func finish() -> ASKHWPRenderedPage {
    ASKHWPRenderedPage(
      index: index,
      sectionIndex: sectionIndex,
      metrics: metrics,
      bodyTextFragments: bodyTextFragments,
      tableFragments: tableFragments,
      imageFragments: imageFragments,
      objectFragments: objectFragments.sorted { lhs, rhs in
        if lhs.object.zOrder != rhs.object.zOrder { return lhs.object.zOrder < rhs.object.zOrder }
        return lhs.id < rhs.id
      }
    )
  }
}
