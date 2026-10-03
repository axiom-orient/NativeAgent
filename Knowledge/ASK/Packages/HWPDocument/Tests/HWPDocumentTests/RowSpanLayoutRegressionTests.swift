import Foundation
import Testing
@testable import HWPDocument

private func rowspanProbeTable(
    id: String = "rowspan",
    mergedHeight: Double = 48,
    explicitRowHeights: [Double?] = [nil, nil]
) -> ASKHWPTable {
    ASKHWPTable(id: id, rows: [
        ASKHWPTableRow(id: "row-0", index: 0, cells: [
            ASKHWPTableCell(id: "merged", rowIndex: 0, columnIndex: 0,
                rowSpan: 2, width: 100, height: mergedHeight, paragraphs: []),
            ASKHWPTableCell(id: "right-0", rowIndex: 0, columnIndex: 1,
                width: 100, height: 24, paragraphs: [])
        ], height: explicitRowHeights[0]),
        ASKHWPTableRow(id: "row-1", index: 1, cells: [
            ASKHWPTableCell(id: "right-1", rowIndex: 1, columnIndex: 1,
                width: 100, height: 24, paragraphs: [])
        ], height: explicitRowHeights[1])
    ], style: .init(cellPadding: 0), width: 200)
}

private func renderRowspanProbe(
    _ table: ASKHWPTable,
    contentHeight: Double = 60
) throws -> ASKHWPRenderedDocument {
    try ASKHWPPageLayoutRenderer().render(ASKHWPDocument(
        format: .hwpx, title: "Rowspan regression",
        sections: [ASKHWPSection(index: 0,
            pageMetrics: .init(width: 240, height: contentHeight,
                marginTop: 0, marginRight: 0, marginBottom: 0, marginLeft: 0),
            paragraphs: [], contentBlocks: [.table(table)])]
    ))
}

@Test("Two-row merged cell contributes its height once and avoids a false page break")
func mergedCellHeightIsAllocatedAcrossRows() throws {
    let rendered = try renderRowspanProbe(rowspanProbeTable())
    let rows = rendered.pages.flatMap(\.tableFragments)
    #expect(rendered.pages.count == 1)
    #expect(rows.map(\.frame.size.height) == [24, 24])
    let merged = try #require(rows.first?.cells.first(where: { $0.rowSpan == 2 }))
    #expect(merged.frame.size.height == 48)
    #expect(rows.map(\.rowRange.start) == [0, 1])
    #expect(rows.map(\.rowRange.end) == [1, 2])
}

@Test("Larger merged content grows the combined span only by its missing height")
func mergedCellHeightDeficitIsAllocatedOnce() throws {
    let rendered = try renderRowspanProbe(rowspanProbeTable(mergedHeight: 100), contentHeight: 120)
    let rows = rendered.pages.flatMap(\.tableFragments)
    #expect(rows.map(\.frame.size.height) == [50, 50])
    let merged = try #require(rows.first?.cells.first(where: { $0.rowSpan == 2 }))
    #expect(merged.frame.size.height == 100)
}

@Test("Explicit row heights and existing row-page split identities stay authoritative")
func mergedCellExplicitRowsAndPageSplitsRemainUnchanged() throws {
    let table = rowspanProbeTable(mergedHeight: 200, explicitRowHeights: [40, 40])
    let rendered = try renderRowspanProbe(table, contentHeight: 60)
    #expect(rendered.pages.count == 2)
    let rows = rendered.pages.flatMap(\.tableFragments)
    #expect(rows.map(\.frame.size.height) == [40, 40])
    #expect(rows.map(\.rowRange.start) == [0, 1])
    #expect(rows.map(\.rowRange.end) == [1, 2])
    let merged = try #require(rows.first?.cells.first(where: { $0.rowSpan == 2 }))
    #expect(merged.frame.size.height == 80)
    #expect(merged.rowSpan == 2)
    // This preserves the existing spanning-cell frame contract; it does not
    // claim newly implemented cross-page cell splitting or repeated headers.
}

@Test("Only inferred rows absorb a merged-height deficit")
func mergedCellPreservesMixedExplicitRowHeight() throws {
    let table = rowspanProbeTable(mergedHeight: 70, explicitRowHeights: [20, nil])
    let rendered = try renderRowspanProbe(table, contentHeight: 100)
    #expect(rendered.pages.flatMap(\.tableFragments).map(\.frame.size.height) == [20, 50])
}

@Test("Nested tables use the same merged-row height allocation")
func nestedMergedCellHeightMatchesTopLevel() throws {
    let inner = rowspanProbeTable(id: "inner")
    let outer = ASKHWPTable(id: "outer", rows: [
        ASKHWPTableRow(id: "outer-row", index: 0, cells: [
            ASKHWPTableCell(id: "outer-cell", rowIndex: 0, columnIndex: 0,
                width: 220, height: 120, paragraphs: [], nestedTables: [inner])
        ])
    ], style: .init(cellPadding: 0), width: 220)
    let rendered = try renderRowspanProbe(outer, contentHeight: 160)
    let nested = try #require(rendered.tableFragments.first(where: { $0.tableID == "inner" }))
    #expect(nested.frame.size.height == 48)
    let merged = try #require(nested.cells.first(where: { $0.rowSpan == 2 }))
    #expect(merged.frame.size.height == 48)
}
