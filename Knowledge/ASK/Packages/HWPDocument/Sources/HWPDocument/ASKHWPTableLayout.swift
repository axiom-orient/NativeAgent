import DocumentCore
import Foundation

struct ASKHWPTableLayoutEngine: Sendable {
  let textLayout: ASKHWPTextLayoutEngine

  func layout(
    table: ASKHWPTable,
    sectionIndex: Int,
    metrics: ASKHWPPageMetrics,
    pageFlow: inout ASKHWPPageFlowState
  ) throws {
    guard !table.rows.isEmpty else { return }
    guard var current = pageFlow.current else {
      throw ASKHWPError.malformedDocument("Internal table layout state was not initialized.")
    }
    let tableWidth = min(table.width ?? metrics.contentWidth, metrics.contentWidth)
    let columnWidths = gridColumnWidths(for: table, targetWidth: tableWidth)
    let columnOffsets = cumulativeOffsets(columnWidths)
    let rowHeights = resolvedRowHeights(for: table, columnWidths: columnWidths)

    for (rowPosition, row) in table.rows.enumerated() {
      let rowHeight = rowHeights[rowPosition]
      if current.cursorY + rowHeight > current.pageBottom, !current.isEmpty {
        current = pageFlow.breakPage(
          committing: current,
          sectionIndex: sectionIndex,
          metrics: metrics,
          includeEmptyCurrent: false
        )
      }

      let rowY = current.cursorY
      let cells = layoutCells(
        in: table,
        row: row,
        rowPosition: rowPosition,
        rowY: rowY,
        tableOriginX: metrics.contentX,
        columnWidths: columnWidths,
        columnOffsets: columnOffsets,
        rowHeights: rowHeights,
        idPrefix: "\(table.id)-row-\(row.index)-cell",
        usesCellMargins: true,
        sectionIndex: sectionIndex
      )
      let borderSegments = collapsedBorderSegments(for: cells, width: table.style.borderWidth)
      current.tableFragments.append(
        ASKHWPRenderedTableFragment(
          id: "\(table.id)-page-\(current.index)-row-\(row.index)",
          tableID: table.id,
          sectionIndex: sectionIndex,
          frame: ASKCanvasRect(x: metrics.contentX, y: rowY, width: tableWidth, height: rowHeight),
          rowRange: ASKPageSourceRange(start: row.index, end: row.index + 1),
          cells: cells,
          style: table.style,
          borderSegments: borderSegments
        ))
      current.cursorY += rowHeight
    }
    current.cursorY += table.style.spacingAfter
    pageFlow.current = current
  }

  /// A spanning cell constrains the combined height of its rows. Explicit row
  /// heights retain their existing authority; only inferred rows absorb a deficit.
  private func resolvedRowHeights(for table: ASKHWPTable, columnWidths: [Double]) -> [Double] {
    var heights = table.rows.map { max($0.height ?? 24, 12) }
    var spans: [(range: Range<Int>, required: Double, column: Int)] = []
    for (rowPosition, row) in table.rows.enumerated() {
      for cell in row.cells {
        let span = min(max(cell.rowSpan, 1), table.rows.count - rowPosition)
        let required = estimatedCellHeight(cell, columnWidths: columnWidths, style: table.style)
        if span == 1 {
          if row.height == nil { heights[rowPosition] = max(heights[rowPosition], required) }
        } else {
          spans.append((rowPosition..<(rowPosition + span), required, cell.columnIndex))
        }
      }
    }
    // Resolve short spans first so wider constraints can reuse their allocation.
    // Canonical ordering makes cell-array order immaterial to height allocation.
    spans.sort {
      if $0.range.count != $1.range.count { return $0.range.count < $1.range.count }
      if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
      if $0.column != $1.column { return $0.column < $1.column }
      return $0.required < $1.required
    }
    for requirement in spans {
      let available = requirement.range.reduce(0.0) { $0 + heights[$1] }
      let deficit = requirement.required - available
      guard deficit > 0 else { continue }
      let inferred = requirement.range.filter { table.rows[$0].height == nil }
      guard !inferred.isEmpty else { continue }
      let addition = deficit / Double(inferred.count)
      for index in inferred { heights[index] += addition }
    }
    return heights
  }

  private func estimatedCellHeight(
    _ cell: ASKHWPTableCell, columnWidths: [Double], style: ASKHWPTableStyle
  ) -> Double {
    let columnIndex = min(max(cell.columnIndex, 0), max(columnWidths.count - 1, 0))
    let span = min(max(cell.columnSpan, 1), max(columnWidths.count - columnIndex, 1))
    let columnWidth = columnWidths[columnIndex..<(columnIndex + span)].reduce(0, +)
    let padding =
      cell.margin == .zero
      ? style.cellPadding
      : max(
        style.cellPadding, cell.margin.left, cell.margin.right, cell.margin.top,
        cell.margin.bottom)
    let textLineCount = max(
      cell.paragraphs.map { paragraph in
        textLayout.breakLines(
          paragraph: paragraph,
          metrics: ASKHWPPageMetrics(
            width: max(columnWidth, 1), height: 10_000, marginTop: padding,
            marginRight: padding, marginBottom: padding, marginLeft: padding
          )
        ).count
      }.reduce(0, +), 1)
    let maxLineHeight =
      cell.paragraphs.map(\.style.lineHeight).max() ?? ASKHWPParagraphStyle.body.lineHeight
    let nestedHeight = cell.nestedTables.reduce(0.0) { partial, table in
      partial + estimatedTableHeight(table, maxWidth: max(columnWidth - padding * 2, 1))
    }
    return max(
      cell.height ?? 0, Double(textLineCount) * maxLineHeight + padding * 2 + nestedHeight)
  }

  private func gridColumnWidths(for table: ASKHWPTable, targetWidth: Double) -> [Double] {
    let columnCount = max(table.columnCount, 1)
    var widths = Array(repeating: 0.0, count: columnCount)
    for row in table.rows {
      for cell in row.cells {
        let columnIndex = min(max(cell.columnIndex, 0), columnCount - 1)
        let span = min(max(cell.columnSpan, 1), max(columnCount - columnIndex, 1))
        guard let width = cell.width, width > 0 else { continue }
        let distributed = width / Double(span)
        for index in columnIndex..<(columnIndex + span) {
          widths[index] = max(widths[index], distributed)
        }
      }
    }
    let observedTotal = widths.reduce(0, +)
    if observedTotal <= 0 {
      return Array(repeating: targetWidth / Double(columnCount), count: columnCount)
    }
    let missingColumns = widths.filter { $0 <= 0 }.count
    if missingColumns > 0 {
      let knownTotal = widths.reduce(0, +)
      let fallback = max(
        (targetWidth - knownTotal) / Double(missingColumns), targetWidth / Double(columnCount))
      widths = widths.map { $0 <= 0 ? fallback : $0 }
    }
    let total = widths.reduce(0, +)
    guard total > 0 else {
      return Array(repeating: targetWidth / Double(columnCount), count: columnCount)
    }
    let scale = targetWidth / total
    return widths.map { max($0 * scale, 1) }
  }

  private func cumulativeOffsets(_ widths: [Double]) -> [Double] {
    var offsets: [Double] = []
    var cursor = 0.0
    for width in widths {
      offsets.append(cursor)
      cursor += width
    }
    return offsets
  }

  private func estimatedTableHeight(_ table: ASKHWPTable, maxWidth: Double) -> Double {
    let widths = gridColumnWidths(for: table, targetWidth: min(table.width ?? maxWidth, maxWidth))
    return resolvedRowHeights(for: table, columnWidths: widths).reduce(0, +)
      + table.style.spacingAfter
  }

  private func layoutNestedTablesInCell(
    _ tables: [ASKHWPTable],
    cellFrame: ASKCanvasRect,
    textFragments: [ASKHWPRenderedTextFragment],
    padding: Double,
    sectionIndex: Int
  ) -> [ASKHWPRenderedTableFragment] {
    guard !tables.isEmpty else { return [] }
    let textBottom =
      textFragments.map { $0.frame.origin.y + $0.frame.size.height }.max()
      ?? (cellFrame.origin.y + padding)
    var cursorY = min(
      max(textBottom + 2, cellFrame.origin.y + padding),
      cellFrame.origin.y + cellFrame.size.height - padding)
    var rendered: [ASKHWPRenderedTableFragment] = []
    for table in tables {
      let maxWidth = max(cellFrame.size.width - padding * 2, 1)
      let tableWidth = min(table.width ?? maxWidth, maxWidth)
      let columnWidths = gridColumnWidths(for: table, targetWidth: tableWidth)
      let rowHeights = resolvedRowHeights(for: table, columnWidths: columnWidths)
      let tableHeight = rowHeights.reduce(0, +)
      guard cursorY + tableHeight <= cellFrame.origin.y + cellFrame.size.height - padding else {
        break
      }
      let columnOffsets = cumulativeOffsets(columnWidths)
      var rowY = cursorY
      var cells: [ASKHWPRenderedTableCellFragment] = []
      for (rowPosition, row) in table.rows.enumerated() {
        cells.append(
          contentsOf: layoutCells(
            in: table,
            row: row,
            rowPosition: rowPosition,
            rowY: rowY,
            tableOriginX: cellFrame.origin.x + padding,
            columnWidths: columnWidths,
            columnOffsets: columnOffsets,
            rowHeights: rowHeights,
            idPrefix: "\(table.id)-nested-row-\(row.index)-cell",
            usesCellMargins: false,
            sectionIndex: sectionIndex
          ))
        rowY += rowHeights[rowPosition]
      }
      let frame = ASKCanvasRect(
        x: cellFrame.origin.x + padding, y: cursorY, width: tableWidth, height: tableHeight)
      rendered.append(
        ASKHWPRenderedTableFragment(
          id: "\(table.id)-nested-\(rendered.count)",
          tableID: table.id,
          sectionIndex: sectionIndex,
          frame: frame,
          rowRange: ASKPageSourceRange(start: 0, end: table.rows.count),
          cells: cells,
          style: table.style,
          borderSegments: collapsedBorderSegments(for: cells, width: table.style.borderWidth)
        ))
      cursorY += tableHeight + table.style.spacingAfter
    }
    return rendered
  }

  private func layoutCells(
    in table: ASKHWPTable,
    row: ASKHWPTableRow,
    rowPosition: Int,
    rowY: Double,
    tableOriginX: Double,
    columnWidths: [Double],
    columnOffsets: [Double],
    rowHeights: [Double],
    idPrefix: String,
    usesCellMargins: Bool,
    sectionIndex: Int
  ) -> [ASKHWPRenderedTableCellFragment] {
    row.cells.map { cell in
      let columnIndex = min(max(cell.columnIndex, 0), max(columnWidths.count - 1, 0))
      let span = min(max(cell.columnSpan, 1), max(columnWidths.count - columnIndex, 1))
      let rowSpan = min(max(cell.rowSpan, 1), max(rowHeights.count - rowPosition, 1))
      let frame = ASKCanvasRect(
        x: tableOriginX + columnOffsets[columnIndex],
        y: rowY,
        width: max(columnWidths[columnIndex..<(columnIndex + span)].reduce(0, +), 1),
        height: max(rowHeights[rowPosition..<(rowPosition + rowSpan)].reduce(0, +), 1)
      )
      let padding =
        usesCellMargins && cell.margin != .zero
        ? max(
          table.style.cellPadding, cell.margin.left, cell.margin.right, cell.margin.top,
          cell.margin.bottom)
        : table.style.cellPadding
      let fragments = textLayout.layoutParagraphsInCell(
        cell.paragraphs,
        cellFrame: frame,
        padding: padding,
        sectionIndex: sectionIndex
      )
      let nested = layoutNestedTablesInCell(
        cell.nestedTables,
        cellFrame: frame,
        textFragments: fragments,
        padding: padding,
        sectionIndex: sectionIndex
      )
      return ASKHWPRenderedTableCellFragment(
        id: "\(idPrefix)-\(cell.columnIndex)",
        rowIndex: cell.rowIndex,
        columnIndex: cell.columnIndex,
        rowSpan: cell.rowSpan,
        columnSpan: cell.columnSpan,
        frame: frame,
        textFragments: fragments,
        nestedTables: nested
      )
    }
  }

  private func collapsedBorderSegments(for cells: [ASKHWPRenderedTableCellFragment], width: Double)
    -> [ASKHWPTableBorderSegment]
  {
    var segments: [String: ASKHWPTableBorderSegment] = [:]
    for cell in cells {
      let x1 = cell.frame.origin.x
      let y1 = cell.frame.origin.y
      let x2 = cell.frame.origin.x + cell.frame.size.width
      let y2 = cell.frame.origin.y + cell.frame.size.height
      addBorderSegment(&segments, x1: x1, y1: y1, x2: x2, y2: y1, width: width)
      addBorderSegment(&segments, x1: x1, y1: y2, x2: x2, y2: y2, width: width)
      addBorderSegment(&segments, x1: x1, y1: y1, x2: x1, y2: y2, width: width)
      addBorderSegment(&segments, x1: x2, y1: y1, x2: x2, y2: y2, width: width)
    }
    return segments.values.sorted { lhs, rhs in
      if lhs.start.y != rhs.start.y { return lhs.start.y < rhs.start.y }
      if lhs.start.x != rhs.start.x { return lhs.start.x < rhs.start.x }
      if lhs.end.y != rhs.end.y { return lhs.end.y < rhs.end.y }
      return lhs.end.x < rhs.end.x
    }
  }

  private func addBorderSegment(
    _ segments: inout [String: ASKHWPTableBorderSegment],
    x1: Double,
    y1: Double,
    x2: Double,
    y2: Double,
    width: Double
  ) {
    let ax = roundedBorderCoordinate(min(x1, x2))
    let ay = roundedBorderCoordinate(min(y1, y2))
    let bx = roundedBorderCoordinate(max(x1, x2))
    let by = roundedBorderCoordinate(max(y1, y2))
    let key = "\(ax),\(ay),\(bx),\(by)"
    let candidate = ASKHWPTableBorderSegment(
      start: ASKCanvasPoint(x: min(x1, x2), y: min(y1, y2)),
      end: ASKCanvasPoint(x: max(x1, x2), y: max(y1, y2)),
      width: width
    )
    if let existing = segments[key], existing.width >= candidate.width { return }
    segments[key] = candidate
  }

  private func roundedBorderCoordinate(_ value: Double) -> Int {
    Int((value * 100).rounded())
  }

}
