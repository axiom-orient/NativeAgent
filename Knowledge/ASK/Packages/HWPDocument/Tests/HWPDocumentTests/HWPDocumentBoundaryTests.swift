import Foundation
import Testing
import DocumentCore
import DocumentRuntime
@testable import HWPDocument

@Test("HWP parser rejects empty input with a typed failure")
func hwpParserRejectsEmptyInput() {
    #expect(throws: ASKHWPError.emptyInput) {
        try ASKPageHWPNativeParser().parse(data: Data())
    }
}

@Test("HWP parser rejects an unknown signature instead of guessing")
func hwpParserRejectsUnknownSignature() {
    #expect(throws: ASKHWPError.self) {
        try ASKPageHWPNativeParser().parse(data: Data("not-a-hwp-document".utf8))
    }
}

@Test("HWP loader keeps file-system location behind DocumentRuntime protocol")
func hwpLoaderConformsToDocumentRuntimeBoundary() {
    let loader: any ASKPageDocumentLoader = ASKPageHWPNativeDocumentLoader(fileName: "document.hwpx")
    _ = loader
}

@Test("HWP loader rejects an external child symlink before compilation")
func hwpLoaderRejectsExternalChildSymlink() async throws {
    try await withHWPTemporaryRoot { rootURL, outsideURL in
        let outsideFile = outsideURL.appendingPathComponent("document.hwpx")
        try Data([0x01]).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("document.hwpx"),
            withDestinationURL: outsideFile
        )

        do {
            _ = try await ASKPageHWPNativeDocumentLoader(fileName: "document.hwpx")
                .loadDocument(from: .init(rootURL: rootURL))
            Issue.record("Expected the external symlink to be rejected")
        } catch let error as ASKHWPError {
            #expect(error == .fileReadFailed("document.hwpx"))
        }
    }
}

@Test("HWP loader allows an in-root child symlink and caller-owned root symlink")
func hwpLoaderAllowsContainedSymlinks() async throws {
    try await withHWPTemporaryRoot { targetRoot, outsideURL in
        let targetFile = targetRoot.appendingPathComponent("real.hwpx")
        try Data().write(to: targetFile)
        try FileManager.default.createSymbolicLink(
            at: targetRoot.appendingPathComponent("document.hwpx"),
            withDestinationURL: targetFile
        )
        let rootAlias = targetRoot.deletingLastPathComponent().appendingPathComponent("hwp-root-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: targetRoot)
        defer { try? FileManager.default.removeItem(at: rootAlias) }

        do {
            _ = try await ASKPageHWPNativeDocumentLoader(fileName: "document.hwpx")
                .loadDocument(from: .init(rootURL: rootAlias))
            Issue.record("Expected the empty target to reach the parser")
        } catch let error as ASKHWPError {
            #expect(error == .emptyInput)
        }
        _ = outsideURL
    }
}

@Test("HWP loader rejects traversal paths")
func hwpLoaderRejectsTraversalPaths() async throws {
    try await withHWPTemporaryRoot { rootURL, outsideURL in
        try await assertHWPPathRejected("../hwp-sibling.hwpx", rootURL: rootURL)
        _ = outsideURL
    }
}

@Test("HWP loader rejects an absolute sibling path")
func hwpLoaderRejectsAbsoluteSiblingPath() async throws {
    try await withHWPTemporaryRoot { rootURL, outsideURL in
        let siblingFile = rootURL.deletingLastPathComponent().appendingPathComponent("hwp-sibling.hwpx")
        try Data([0x01]).write(to: siblingFile)
        defer { try? FileManager.default.removeItem(at: siblingFile) }

        try await assertHWPPathRejected(siblingFile.path, rootURL: rootURL)
        _ = outsideURL
    }
}

@Test("HWP loader reports a dangling contained link as a file-read failure")
func hwpLoaderReportsDanglingContainedSymlink() async throws {
    try await withHWPTemporaryRoot { rootURL, outsideURL in
        let link = rootURL.appendingPathComponent("document-\(UUID().uuidString).hwpx")
        let destination = rootURL.appendingPathComponent("missing-inside.hwpx")
        try await assertDanglingHWPLink(link, destination: destination, rootURL: rootURL)
        _ = outsideURL
    }
}

@Test("HWP loader reports a dangling external link as a file-read failure")
func hwpLoaderReportsDanglingExternalSymlink() async throws {
    try await withHWPTemporaryRoot { rootURL, outsideURL in
        let link = rootURL.appendingPathComponent("document-\(UUID().uuidString).hwpx")
        let destination = outsideURL.appendingPathComponent("missing-outside.hwpx")
        try await assertDanglingHWPLink(link, destination: destination, rootURL: rootURL)
    }
}

private func assertHWPPathRejected(_ fileName: String, rootURL: URL) async throws {
    do {
        _ = try await ASKPageHWPNativeDocumentLoader(fileName: fileName)
            .loadDocument(from: .init(rootURL: rootURL))
        Issue.record("Expected path rejection for \(fileName)")
    } catch let error as ASKHWPError {
        #expect(error == .fileReadFailed(fileName))
    }
}

private func assertDanglingHWPLink(_ link: URL, destination: URL, rootURL: URL) async throws {
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    do {
        _ = try await ASKPageHWPNativeDocumentLoader(fileName: link.lastPathComponent)
            .loadDocument(from: .init(rootURL: rootURL))
        Issue.record("Expected dangling symlink read failure")
    } catch let error as ASKHWPError {
        #expect(error == .fileReadFailed(link.path))
    }
}

private func withHWPTemporaryRoot(_ body: (URL, URL) async throws -> Void) async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hwp-loader-\(UUID().uuidString)", isDirectory: true)
    let outsideURL = rootURL.deletingLastPathComponent()
        .appendingPathComponent("hwp-loader-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: outsideURL)
    }
    try await body(rootURL, outsideURL)
}

@Test("byte cursor does not advance when a fixed-width read fails")
func byteCursorDoesNotAdvanceOnFailedFixedWidthRead() {
    var cursor = ASKByteCursor(bytes: [0x01])
    #expect(throws: ASKHWPError.self) {
        try cursor.readUInt16LE()
    }
    #expect(cursor.offset == 0)
    #expect(cursor.remainingCount == 1)
}

@Test("byte cursor rejects an offset outside the source without trapping")
func byteCursorRejectsExtremeOffset() {
    var cursor = ASKByteCursor(bytes: [0x01], offset: Int.max)
    #expect(throws: ASKHWPError.self) {
        try cursor.readBytes(count: 1)
    }
    #expect(cursor.remainingCount == 0)
}

@Test("HWP compressed sections accept raw DEFLATE and zlib-wrapped streams")
func hwpCompressedSectionsAcceptBothDeflateWrappers() throws {
    let raw = Data([0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])
    let zlib = Data([
        0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00,
        0x06, 0x2C, 0x02, 0x15
    ])

    #expect(try ASKDeflateDecoder.inflateHWPStream(raw) == Data("hello".utf8))
    #expect(try ASKDeflateDecoder.inflateHWPStream(zlib) == Data("hello".utf8))
}

@Test("HWP parser enforces its caller-configured input limit before format detection")
func hwpParserRejectsInputOverConfiguredLimit() {
    let parser = ASKPageHWPNativeParser(
        limits: .init(
            maximumInputByteCount: 16,
            maximumDecodedStreamByteCount: 16,
            maximumDecodedTotalByteCount: 32,
            maximumEntryOrSectionCount: 4
        )
    )

    do {
        _ = try parser.parse(data: Data(repeating: 0x00, count: 17))
        Issue.record("Expected the configured input limit to reject the data.")
    } catch let error as ASKHWPError {
        guard case .unsupportedFeature(let message) = error else {
            Issue.record("Expected an input-limit error, got \(error).")
            return
        }
        #expect(message == "Input exceeds the configured 16-byte limit.")
    } catch {
        Issue.record("Expected ASKHWPError, got \(error).")
    }
}

@Test("decoded HWP parser limits preserve constructor invariants")
func decodedHWPParserLimitsRejectInvalidRelationships() {
    let data = Data(#"""
        {
        "maximumInputByteCount": 16,
        "maximumDecodedStreamByteCount": 32,
        "maximumDecodedTotalByteCount": 16,
        "maximumEntryOrSectionCount": 4
    }
    """#.utf8)

    do {
        _ = try JSONDecoder().decode(ASKHWPParserLimits.self, from: data)
        Issue.record("Expected invalid parser-limit relationships to be rejected.")
    } catch DecodingError.dataCorrupted(let context) {
        #expect(context.codingPath.last?.stringValue == "maximumDecodedTotalByteCount")
        #expect(context.debugDescription == "maximumDecodedTotalByteCount must cover one decoded stream")
    } catch {
        Issue.record("Expected a data-corrupted decoding error, got \(error).")
    }
}

@Test("HWP DEFLATE output limit is enforced and keeps the primary diagnostic")
func hwpDeflateOutputLimitIsEnforced() {
    let raw = Data([0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])

    do {
        _ = try ASKDeflateDecoder.inflateHWPStream(raw, maxOutputSize: 4)
        Issue.record("Expected the configured DEFLATE output limit to reject the stream.")
    } catch let error as ASKHWPError {
        guard case .decompressionFailed(let message) = error else {
            Issue.record("Expected a decompression failure, got \(error).")
            return
        }
        #expect(message.contains("output exceeds configured limit"))
    } catch {
        Issue.record("Expected ASKHWPError, got \(error).")
    }
}

@Test("CFB rejects impossible FAT counts before allocating based on untrusted header values")
func cfbRejectsImpossibleDeclaredFATCount() {
    var bytes = cfbFixture(sectorCount: 0)
    writeUInt32(1, to: &bytes, at: 0x2C)

    #expect(throws: ASKHWPError.self) {
        _ = try ASKCFBReader(
            data: bytes,
            maximumStreamByteCount: 1_024,
            maximumMiniStreamByteCount: 2_048
        )
    }
}

@Test("CFB rejects cyclic DIFAT chains instead of following declared iterations")
func cfbRejectsCyclicDIFATChain() {
    var bytes = cfbFixture(sectorCount: 2)
    writeUInt32(0, to: &bytes, at: 0x44)
    writeUInt32(2, to: &bytes, at: 0x48)
    writeUInt32(0, to: &bytes, at: 512 + 508)

    do {
        _ = try ASKCFBReader(
            data: bytes,
            maximumStreamByteCount: 1_024,
            maximumMiniStreamByteCount: 2_048
        )
        Issue.record("Expected the cyclic DIFAT chain to be rejected.")
    } catch let ASKHWPError.malformedContainer(message) {
        #expect(message.contains("DIFAT chain contains a cycle"))
    } catch {
        Issue.record("Expected a CFB cycle error, got \(error).")
    }
}

private func cfbFixture(sectorCount: Int) -> Data {
    var bytes = Data(repeating: 0, count: 512 + max(sectorCount, 0) * 512)
    bytes.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    writeUInt16(3, to: &bytes, at: 0x1A)
    writeUInt16(0xFFFE, to: &bytes, at: 0x1C)
    writeUInt16(9, to: &bytes, at: 0x1E)
    writeUInt16(6, to: &bytes, at: 0x20)
    writeUInt32(0xFFFF_FFFE, to: &bytes, at: 0x30)
    writeUInt32(0x0000_1000, to: &bytes, at: 0x38)
    writeUInt32(0xFFFF_FFFE, to: &bytes, at: 0x3C)
    writeUInt32(0xFFFF_FFFF, to: &bytes, at: 0x44)
    for offset in stride(from: 0x4C, to: 0x4C + 109 * 4, by: 4) {
        writeUInt32(0xFFFF_FFFF, to: &bytes, at: offset)
    }
    return bytes
}

private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
    for byteOffset in 0..<4 {
        data[offset + byteOffset] = UInt8(truncatingIfNeeded: value >> UInt32(byteOffset * 8))
    }
}
