import Foundation
import Testing

@testable import HWPDocument

private let representativeSectionXML = """
  <section xmlns:hp="urn:example:hwp">
    <hp:pagePr width="59500" height="84200">
      <hp:margin top="5670" right="5670" bottom="5670" left="5670" />
    </hp:pagePr>
    <hp:p styleIDRef="body" align="center">
      <hp:run bold="true"><hp:t>Hello</hp:t></hp:run>
      <hp:run italic="true"><hp:t> world</hp:t></hp:run>
    </hp:p>
    <hp:tbl id="table-1">
      <hp:tr id="row-1">
        <hp:tc id="cell-1"><hp:p><hp:run><hp:t>Cell text</hp:t></hp:run></hp:p></hp:tc>
      </hp:tr>
    </hp:tbl>
    <hp:pic id="image-1" binaryItemIDRef="BIN0001" alt="Diagram" width="7200" height="3600" />
    <hp:rect id="shape-1" width="7200" height="3600">
      <hp:drawText>Shape text</hp:drawText>
    </hp:rect>
  </section>
  """

@Test("HWPX section parser preserves paragraph, table, image, and object order")
func hwpxSectionParserPreservesRepresentativeContent() throws {
  let parsed = try ASKHWPXSectionXMLParser(sourcePath: "Contents/section0.xml")
    .parse(data: Data(representativeSectionXML.utf8))

  #expect(parsed.pageMetrics != nil)
  #expect(parsed.paragraphs.map(\.plainText) == ["Hello world"])
  #expect(parsed.contentBlocks.count == 4)

  guard parsed.contentBlocks.count == 4 else { return }
  guard case .paragraph(let paragraph) = parsed.contentBlocks[0] else {
    Issue.record("first block must remain the paragraph")
    return
  }
  #expect(paragraph.style.alignment == .center)
  #expect(paragraph.runs.count == 2)
  #expect(paragraph.runs[0].attributes.isBold)
  #expect(paragraph.runs[1].attributes.isItalic)

  guard case .table(let table) = parsed.contentBlocks[1] else {
    Issue.record("second block must remain the table")
    return
  }
  #expect(table.rows.count == 1)
  #expect(table.rows.first?.cells.first?.paragraphs.first?.plainText == "Cell text")

  guard case .image(let image) = parsed.contentBlocks[2] else {
    Issue.record("third block must remain the image")
    return
  }
  #expect(image.referenceID == "BIN0001")
  #expect(image.altText == "Diagram")

  guard case .drawObject(let object) = parsed.contentBlocks[3] else {
    Issue.record("fourth block must remain the draw object")
    return
  }
  #expect(object.text == "Shape text")
}

@Test("HWP layout renderer materializes each representative block kind")
func hwpLayoutRendererMaterializesRepresentativeBlocks() throws {
  let parsed = try ASKHWPXSectionXMLParser(sourcePath: "Contents/section0.xml")
    .parse(data: Data(representativeSectionXML.utf8))
  let document = ASKHWPDocument(
    format: .hwpx,
    title: "Fixture",
    sections: [
      ASKHWPSection(
        index: 0,
        sourcePath: "Contents/section0.xml",
        pageMetrics: parsed.pageMetrics,
        paragraphs: parsed.paragraphs,
        contentBlocks: parsed.contentBlocks
      )
    ]
  )

  let rendered = try ASKHWPPageLayoutRenderer().render(document)

  #expect(!rendered.pages.isEmpty)
  #expect(rendered.textFragments.map(\.text).joined() == "Hello worldCell text")
  #expect(rendered.tableFragments.count == 1)
  #expect(rendered.imageFragments.count == 1)
  #expect(rendered.objectFragments.count == 1)
}

@Test("HWPX section parser resets all accumulated state between parses")
func hwpxSectionParserCanBeReusedWithoutStateLeakage() throws {
  let parser = ASKHWPXSectionXMLParser(sourcePath: "Contents/section0.xml")
  _ = try parser.parse(data: Data(representativeSectionXML.utf8))

  let secondXML = """
    <section xmlns:hp="urn:example:hwp">
      <hp:p><hp:run><hp:t>Second</hp:t></hp:run></hp:p>
    </section>
    """
  let second = try parser.parse(data: Data(secondXML.utf8))

  #expect(second.paragraphs.map(\.plainText) == ["Second"])
  #expect(second.contentBlocks.count == 1)
  #expect(second.pageMetrics == nil)
}

@Test("HWP page lifecycle reducer applies explicit page transitions deterministically")
func hwpPageFlowReducerIsDeterministic() {
  let metrics = ASKHWPPageMetrics(
    width: 100,
    height: 100,
    marginTop: 10,
    marginRight: 10,
    marginBottom: 10,
    marginLeft: 10
  )
  var first = ASKHWPPageFlowState()
  var second = ASKHWPPageFlowState()
  let events: [ASKHWPPageFlowEvent] = [
    .beginSection(sectionIndex: 0, metrics: metrics),
    .breakPage(sectionIndex: 0, metrics: metrics, includeEmptyCurrent: true),
    .finishDocument,
  ]

  for event in events {
    first.apply(event)
    second.apply(event)
  }

  #expect(first == second)
  #expect(first.pages.map(\.index) == [0])
  #expect(first.current == nil)
}
