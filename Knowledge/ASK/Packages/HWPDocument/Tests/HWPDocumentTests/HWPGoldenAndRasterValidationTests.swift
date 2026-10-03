import Foundation
import Testing

@testable import HWPDocument

private func makeGoldenFixtureDocument() throws -> ASKHWPDocument {
    let xml = """
    <section xmlns:hp="urn:example:hwp">
      <hp:pagePr width="59500" height="84200">
        <hp:margin top="5670" right="5670" bottom="5670" left="5670" />
      </hp:pagePr>
      <hp:p><hp:run><hp:t>Golden HWPX fixture</hp:t></hp:run></hp:p>
    </section>
    """
    let parsed = try ASKHWPXSectionXMLParser(sourcePath: "Contents/section0.xml")
        .parse(data: Data(xml.utf8))
    return ASKHWPDocument(
        format: .hwpx,
        title: "Golden fixture",
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
}

@Test("HWP golden snapshot round-trips and detects a meaningful change")
func hwpGoldenSnapshotRoundTripsAndDetectsChange() throws {
    let document = try makeGoldenFixtureDocument()
    let rendered = try ASKHWPPageLayoutRenderer().render(document)
    let snapshotter = ASKHWPRegressionSnapshotter()
    let snapshot = snapshotter.makeSnapshot(parsedDocument: document, renderedDocument: rendered)
    let store = ASKHWPRegressionSnapshotStore()
    let restored = try store.decode(store.encode(snapshot))

    #expect(ASKHWPRegressionVerifier().compare(actual: restored, expected: snapshot).passed)

    let changed = ASKHWPRegressionSnapshot(
        title: snapshot.title,
        format: snapshot.format,
        plainText: snapshot.plainText + " changed",
        pageCount: snapshot.pageCount,
        pageMetrics: snapshot.pageMetrics,
        textFragmentCount: snapshot.textFragmentCount,
        tableFragmentCount: snapshot.tableFragmentCount,
        imageFragmentCount: snapshot.imageFragmentCount,
        objectFragmentCount: snapshot.objectFragmentCount,
        parsedTableCount: snapshot.parsedTableCount,
        parsedImageCount: snapshot.parsedImageCount,
        parsedObjectCount: snapshot.parsedObjectCount,
        binaryObjectCount: snapshot.binaryObjectCount,
        svgSnapshot: snapshot.svgSnapshot,
        svgFNV1A64: snapshot.svgFNV1A64,
        metadata: snapshot.metadata
    )
    let report = ASKHWPRegressionVerifier().compare(actual: changed, expected: snapshot)
    #expect(!report.passed)
    #expect(report.differences.contains { $0.field == "plainText" })
}

@Test("HWP raster differ reports exact and changed candidates accurately")
func hwpRasterDifferReportsPixelQuality() throws {
    let reference = try ASKHWPReferenceRasterImage(
        width: 2,
        height: 1,
        rgba8: Data([0, 0, 0, 255, 255, 255, 255, 255])
    )
    let identical = try ASKHWPReferenceRasterImage(width: 2, height: 1, rgba8: reference.rgba8)
    let changed = try ASKHWPReferenceRasterImage(
        width: 2,
        height: 1,
        rgba8: Data([0, 0, 0, 255, 200, 255, 255, 255])
    )
    let differ = ASKHWPReferenceImageDiffer()

    let exact = try differ.diff(reference: reference, candidate: identical)
    #expect(exact.passed)
    #expect(exact.changedPixelCount == 0)
    #expect(exact.meanAbsoluteChannelError == 0)

    let mismatch = try differ.diff(reference: reference, candidate: changed)
    #expect(!mismatch.passed)
    #expect(mismatch.changedPixelCount == 1)
    #expect(mismatch.changedPixelRatio == 0.5)
    #expect(mismatch.maxObservedChannelDelta == 55)
}
