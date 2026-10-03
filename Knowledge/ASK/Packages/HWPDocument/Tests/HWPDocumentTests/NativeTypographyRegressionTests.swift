import Foundation
import Testing
@testable import HWPDocument
#if canImport(AppKit)
import AppKit

@Test("Native system-font glyph advances fit every laid-out table line")
@MainActor func nativeTypographyTableLinesFitActualSystemFont() throws {
    let samples: [(ASKHWPTextAttributes, String)] = [
        (.init(), String(repeating: "W", count: 100)),
        (.init(isBold: true), String(repeating: "WIDE WORDS MM WWW ", count: 8)),
        (.init(isItalic: true), String(repeating: "office affinity wavy WORLD ", count: 7)),
        (.init(isBold: true, isItalic: true), String(repeating: "BOLD ITALIC Wide WORLD ", count: 7)),
        (.init(), String(repeating: "한글 문서 경계 👩🏽‍💻 café ", count: 8))
    ]
    for (attributes, sourceText) in samples {
        let cell = ASKHWPTableCell(id: "text", rowIndex: 0, columnIndex: 0, width: 180, height: 240,
            paragraphs: [.init(index: 0, runs: [.init(text: sourceText, attributes: attributes)])])
        let table = ASKHWPTable(id: "native-width", rows: [.init(id: "row", index: 0, cells: [cell])],
            style: .init(cellPadding: 4), width: 180)
        let document = ASKHWPDocument(format: .hwpx, title: "Native width", sections: [.init(index: 0,
            pageMetrics: .init(width: 260, height: 400, marginTop: 40, marginRight: 40, marginBottom: 40, marginLeft: 40),
            paragraphs: [], contentBlocks: [.table(table)])])
        let rendered = try ASKHWPPageLayoutRenderer().render(document)
        let output = try #require(rendered.pages.first?.tableFragments.first?.cells.first)
        #expect(String(output.textFragments.map(\.text).joined().filter { !$0.isWhitespace }) == String(sourceText.filter { !$0.isWhitespace }))
        for fragment in output.textFragments {
            var font = NSFont.systemFont(ofSize: fragment.fontSize, weight: attributes.isBold ? .bold : .regular)
            if attributes.isItalic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            // Independent platform measurement; no heuristic from the production
            // measurer is used to establish the expected glyph advance.
            let actualWidth = (fragment.text as NSString).size(withAttributes: [.font: font]).width
            #expect(actualWidth <= fragment.frame.size.width + 0.01)
            #expect(fragment.frame.origin.x + actualWidth <= output.frame.origin.x + output.frame.size.width - 4 + 0.01)
        }
    }
}
#endif

@Test("Fractional line heights preserve the last line in an inferred table row")
func nativeTypographyFractionalRowKeepsItsLastLine() throws {
    func paragraph(_ text: String) -> [ASKHWPParagraph] { [.init(index: 0, runs: [.init(text: text)])] }
    let bottomText = "RIGHT BOTTOM " + String(repeating: "W", count: 70) + " END"
    let table = ASKHWPTable(id: "fractional-height", rows: [
        .init(id: "r0", index: 0, cells: [
            .init(id: "merged", rowIndex: 0, columnIndex: 0, rowSpan: 2, width: 280, height: 120,
                paragraphs: paragraph("LEFT MERGED " + String(repeating: "W", count: 60) + " END")),
            .init(id: "top", rowIndex: 0, columnIndex: 1, width: 280, height: 60,
                paragraphs: paragraph("RIGHT TOP " + String(repeating: "W", count: 80) + " END"))
        ]),
        .init(id: "r1", index: 1, cells: [
            .init(id: "bottom", rowIndex: 1, columnIndex: 1, width: 280, height: 60, paragraphs: paragraph(bottomText))
        ])
    ], style: .init(cellPadding: 4), width: 560)
    let document = ASKHWPDocument(format: .hwpx, title: "Fractional row", sections: [.init(index: 0,
        pageMetrics: .init(width: 640, height: 400, marginTop: 40, marginRight: 40, marginBottom: 40, marginLeft: 40),
        paragraphs: [], contentBlocks: [.table(table)])])
    let rendered = try ASKHWPPageLayoutRenderer().render(document)
    let bottom = try #require(rendered.pages.flatMap(\.tableFragments).flatMap(\.cells).first { $0.rowIndex == 1 && $0.columnIndex == 1 })
    #expect(String(bottom.textFragments.map(\.text).joined().filter { !$0.isWhitespace }) == String(bottomText.filter { !$0.isWhitespace }))
    #expect(bottom.textFragments.last?.text.hasSuffix("END") == true)
}
