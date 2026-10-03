import Foundation

struct ASKHWPXTableAccumulator: Sendable, Hashable {
  private let sourcePath: String
  private let styles: ASKHWPXStyleCatalog
  private var tableBuilder: TableBuilder?
  private var rowBuilder: RowBuilder?
  private var cellBuilder: CellBuilder?
  private var tableStack: [TableParserFrame] = []
  private var cellTextDepth = 0

  init(sourcePath: String, styles: ASKHWPXStyleCatalog = .empty) {
    self.sourcePath = sourcePath
    self.styles = styles
  }

  var isActive: Bool { tableBuilder != nil }

  mutating func consumeStart(
    localName: String,
    depth: Int,
    attributes: AttributeLookup,
    completedBlockCount: Int
  ) -> Bool {
    if isActive, ASKHWPXAttributeDecoder.startsTable(localName), cellBuilder != nil {
      pushActiveTableFrame()
      startTable(attributes, depth: depth, completedBlockCount: completedBlockCount)
      return true
    }

    if isActive {
      updateActiveTable(localName, depth: depth, attributes: attributes)
      return true
    }

    guard ASKHWPXAttributeDecoder.startsTable(localName) else { return false }
    startTable(attributes, depth: depth, completedBlockCount: completedBlockCount)
    return true
  }

  mutating func consumeCharacters(_ characters: String) -> Bool {
    guard isActive else { return false }
    if cellBuilder != nil, cellTextDepth > 0 {
      cellBuilder?.textParts.append(characters)
    }
    return true
  }

  mutating func consumeEnd(localName: String, depth: Int) -> ASKHWPTable? {
    guard isActive else { return nil }
    if localName == "t" || localName == "text" {
      cellTextDepth = max(cellTextDepth - 1, 0)
    } else if localName == "p", cellBuilder != nil {
      appendCellParagraphBreakIfNeeded()
    } else if let cellBuilder, depth == cellBuilder.depth,
      ASKHWPXAttributeDecoder.startsTableCell(localName)
    {
      finishCurrentCell()
    } else if let rowBuilder, depth == rowBuilder.depth,
      ASKHWPXAttributeDecoder.startsTableRow(localName)
    {
      finishCurrentRow()
    } else if let tableBuilder, depth == tableBuilder.depth,
      ASKHWPXAttributeDecoder.startsTable(localName)
    {
      return finishCurrentTable()
    }
    return nil
  }

  private mutating func startTable(
    _ attributes: AttributeLookup,
    depth: Int,
    completedBlockCount: Int
  ) {
    tableBuilder = TableBuilder(
      id: attributes.string(["id", "instanceID", "instid", "name"])
        ?? "table-\(completedBlockCount + tableStack.count + 1)",
      sourcePath: sourcePath,
      depth: depth,
      style: ASKHWPTableStyle(
        borderWidth: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["borderWidth", "border", "lineWidth"]
        ) ?? 0.75,
        cellPadding: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["cellPadding", "padding"]
        ) ?? 4,
        spacingAfter: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["spacingAfter", "after"]
        ) ?? 8
      ),
      width: ASKHWPXAttributeDecoder.pointDimension(attributes, keys: ["width", "w"]),
      repeatHeader: attributes.bool(["repeatHeader", "repeatHeaderRow"]) ?? false,
      cellSpacing: ASKHWPXAttributeDecoder.pointDimension(
        attributes, keys: ["cellSpacing", "cellspace"]
      ) ?? 0,
      borderFillIDRef: attributes.string([
        "borderFillIDRef", "borderFillIdRef", "borderFillID", "borderFillId",
      ]),
      inMargin: ASKHWPXAttributeDecoder.insets(from: attributes),
      outMargin: .zero
    )
    rowBuilder = nil
    cellBuilder = nil
    cellTextDepth = 0
  }

  private mutating func pushActiveTableFrame() {
    guard let tableBuilder else { return }
    tableStack.append(
      TableParserFrame(
        table: tableBuilder,
        row: rowBuilder,
        cell: cellBuilder,
        cellTextDepth: cellTextDepth
      )
    )
    self.tableBuilder = nil
    rowBuilder = nil
    cellBuilder = nil
    cellTextDepth = 0
  }

  private mutating func updateActiveTable(
    _ localName: String,
    depth: Int,
    attributes: AttributeLookup
  ) {
    if rowBuilder == nil, ASKHWPXAttributeDecoder.startsTableRow(localName) {
      let rowIndex = tableBuilder?.rows.count ?? 0
      rowBuilder = RowBuilder(
        id: attributes.string(["id", "name"]) ?? "row-\(rowIndex + 1)",
        index: rowIndex,
        depth: depth,
        height: ASKHWPXAttributeDecoder.pointDimension(attributes, keys: ["height", "h"])
      )
      return
    }

    if rowBuilder != nil, cellBuilder == nil,
      ASKHWPXAttributeDecoder.startsTableCell(localName)
    {
      let rowIndex = rowBuilder?.index ?? 0
      let columnIndex = rowBuilder?.cells.reduce(0) { $0 + max($1.columnSpan, 1) } ?? 0
      cellBuilder = CellBuilder(
        id: attributes.string(["id", "name"]) ?? "cell-\(rowIndex + 1)-\(columnIndex + 1)",
        rowIndex: rowIndex,
        columnIndex: columnIndex,
        depth: depth,
        rowSpan: attributes.int(["rowSpan", "rowspan", "vMerge"]) ?? 1,
        columnSpan: attributes.int(["colSpan", "colspan", "columnSpan", "gridSpan"]) ?? 1,
        width: ASKHWPXAttributeDecoder.pointDimension(attributes, keys: ["width", "w"]),
        height: ASKHWPXAttributeDecoder.pointDimension(attributes, keys: ["height", "h"]),
        margin: ASKHWPXAttributeDecoder.insets(from: attributes),
        borderFillIDRef: attributes.string([
          "borderFillIDRef", "borderFillIdRef", "borderFillID", "borderFillId",
        ])
      )
      return
    }

    switch localName {
    case "sz":
      if var tableBuilder {
        tableBuilder.width =
          tableBuilder.width
          ?? ASKHWPXAttributeDecoder.pointDimension(attributes, keys: ["width", "w"])
        self.tableBuilder = tableBuilder
      }
    case "inmargin":
      if var tableBuilder {
        tableBuilder.inMargin = ASKHWPXAttributeDecoder.insets(from: attributes)
        self.tableBuilder = tableBuilder
      }
    case "outmargin":
      if var tableBuilder {
        tableBuilder.outMargin = ASKHWPXAttributeDecoder.insets(from: attributes)
        self.tableBuilder = tableBuilder
      }
    case "cellspacing":
      if var tableBuilder {
        tableBuilder.cellSpacing =
          ASKHWPXAttributeDecoder.pointDimension(
            attributes, keys: ["value", "width", "w"]
          ) ?? tableBuilder.cellSpacing
        self.tableBuilder = tableBuilder
      }
    case "cellmargin":
      if var cellBuilder {
        cellBuilder.margin = ASKHWPXAttributeDecoder.insets(from: attributes)
        self.cellBuilder = cellBuilder
      }
    case "celladdr":
      if var cellBuilder {
        cellBuilder.rowIndex = attributes.int(["rowAddr", "row"]) ?? cellBuilder.rowIndex
        cellBuilder.columnIndex =
          attributes.int(["colAddr", "column", "col"])
          ?? cellBuilder.columnIndex
        self.cellBuilder = cellBuilder
      }
    case "cellspan":
      if var cellBuilder {
        cellBuilder.rowSpan = attributes.int(["rowSpan", "rowspan"]) ?? cellBuilder.rowSpan
        cellBuilder.columnSpan =
          attributes.int([
            "colSpan", "colspan", "columnSpan", "gridSpan",
          ]) ?? cellBuilder.columnSpan
        self.cellBuilder = cellBuilder
      }
    case "cellsz":
      if var cellBuilder {
        cellBuilder.width =
          ASKHWPXAttributeDecoder.pointDimension(
            attributes, keys: ["width", "w"]
          ) ?? cellBuilder.width
        cellBuilder.height =
          ASKHWPXAttributeDecoder.pointDimension(
            attributes, keys: ["height", "h"]
          ) ?? cellBuilder.height
        self.cellBuilder = cellBuilder
      }
    case "t", "text":
      if cellBuilder != nil { cellTextDepth += 1 }
    case "linebreak", "linebreakforlatin", "br":
      cellBuilder?.textParts.append("\n")
    case "tab":
      cellBuilder?.textParts.append("\t")
    default:
      break
    }
  }

  private mutating func appendCellParagraphBreakIfNeeded() {
    guard let last = cellBuilder?.textParts.last, !last.hasSuffix("\n") else { return }
    cellBuilder?.textParts.append("\n")
  }

  private mutating func finishCurrentCell() {
    guard let cellBuilder else { return }
    var paragraphs = cellBuilder.paragraphs
    let text = cellBuilder.textParts.joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty, paragraphs.isEmpty {
      paragraphs.append(
        ASKHWPParagraph(
          index: paragraphs.count,
          runs: [ASKHWPTextRun(text: text)],
          sourcePath: sourcePath
        )
      )
    }
    let cell = ASKHWPTableCell(
      id: cellBuilder.id,
      rowIndex: cellBuilder.rowIndex,
      columnIndex: cellBuilder.columnIndex,
      rowSpan: cellBuilder.rowSpan,
      columnSpan: cellBuilder.columnSpan,
      width: cellBuilder.width,
      height: cellBuilder.height,
      paragraphs: paragraphs.map { styles.resolve(paragraph: $0) },
      margin: cellBuilder.margin,
      borderFillIDRef: cellBuilder.borderFillIDRef,
      nestedTables: cellBuilder.nestedTables
    )
    rowBuilder?.cells.append(cell)
    cellTextDepth = 0
    self.cellBuilder = nil
  }

  private mutating func finishCurrentRow() {
    guard let rowBuilder else { return }
    tableBuilder?.rows.append(
      ASKHWPTableRow(
        id: rowBuilder.id,
        index: rowBuilder.index,
        cells: rowBuilder.cells,
        height: rowBuilder.height
      )
    )
    self.rowBuilder = nil
  }

  private mutating func finishCurrentTable() -> ASKHWPTable? {
    guard let tableBuilder else { return nil }
    let table = ASKHWPTable(
      id: tableBuilder.id,
      sourcePath: tableBuilder.sourcePath,
      rows: tableBuilder.rows,
      style: tableBuilder.style,
      width: tableBuilder.width,
      repeatHeader: tableBuilder.repeatHeader,
      cellSpacing: tableBuilder.cellSpacing,
      borderFillIDRef: tableBuilder.borderFillIDRef,
      inMargin: tableBuilder.inMargin,
      outMargin: tableBuilder.outMargin
    )
    if let frame = tableStack.popLast() {
      self.tableBuilder = frame.table
      rowBuilder = frame.row
      cellBuilder = frame.cell
      cellTextDepth = frame.cellTextDepth
      cellBuilder?.nestedTables.append(table)
      return nil
    }
    self.tableBuilder = nil
    rowBuilder = nil
    cellBuilder = nil
    cellTextDepth = 0
    return table
  }
}
