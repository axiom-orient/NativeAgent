@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain

@Suite("PNG framing and bounded decode")
struct PNGStructureTests {
  @Test func crcHasAnIndependentPublishedCheckVector() {
    #expect(ChatGPTPNGStructure.crc32(Array("123456789".utf8)) == 0xcbf4_3926)
  }

  @Test func fullPNGDimensionsAndAlphaAreObserved() throws {
    let header = try ChatGPTPNGStructure.parse(PNGTestFixture.png())
    #expect(header.width == 2 && header.height == 1 && header.bitDepth == 8)
    #expect(header.colorType == 6 && header.alphaCapable && !header.isAnimated)
  }

  @Test func everyTruncatedPrefixIsRejected() {
    let bytes = PNGTestFixture.png()
    for count in 0..<bytes.count {
      #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(Data(bytes.prefix(count))) }
    }
  }

  @Test func headerOnlyCRCChangeTrailingBytesAndEmptyDataAreNotImages() {
    let bytes = PNGTestFixture.png()
    var badCRC = bytes; badCRC[29] ^= 1
    let cases = [Data(bytes.prefix(33)), badCRC, bytes + Data([0]),
      PNGTestFixture.framed(imageData: []), PNGTestFixture.framed(includeEnd: false)]
    for value in cases { #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(value) } }
  }

  @Test func nonzeroDataStartIndexDoesNotChangeParsing() throws {
    let original = PNGTestFixture.png()
    let storage = Data([99, 98, 97]) + original
    let slice = storage.dropFirst(3)
    let header = try ChatGPTPNGStructure.parse(slice)
    #expect(header.width == 2 && header.height == 1)
  }

  @Test func dimensionAndByteCapsApplyBeforeDecodedAllocation() throws {
    try ChatGPTPNGStructure.admitDimensions(width: 4096, height: 4096)
    for size in [(0, 1), (1, 0), (-1, 1), (Int.max, Int.max), (4097, 4096)] {
      #expect(throws: AgentError.self) { try ChatGPTPNGStructure.admitDimensions(width: size.0, height: size.1) }
    }
    for width in [UInt32(0), 0x8000_0000, 0xffff_ffff] {
      #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(PNGTestFixture.framed(width: width)) }
    }
    let bytes = PNGTestFixture.png()
    #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(bytes, maximumBytes: bytes.count - 1) }
    #expect(try ChatGPTPNGStructure.parse(bytes, maximumBytes: bytes.count).width == 2)
  }

  @Test func paletteTransparencyCannotExceedPaletteEntries() throws {
    let palette = PNGTestFixture.chunk("PLTE", [255, 0, 0])
    let good = PNGTestFixture.framed(depth: 1, color: 3, before: [palette, PNGTestFixture.chunk("tRNS", [0])])
    #expect(try ChatGPTPNGStructure.parse(good).alphaCapable)
    let bad = PNGTestFixture.framed(depth: 1, color: 3, before: [palette, PNGTestFixture.chunk("tRNS", [0, 255])])
    #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(bad) }
    #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(PNGTestFixture.framed(depth: 1, color: 3)) }
  }

  @Test func unknownCriticalAndSplitIDATAreRejected() {
    let values = [PNGTestFixture.framed(before: [PNGTestFixture.chunk("ABCD", [])]),
      PNGTestFixture.framed(after: [PNGTestFixture.chunk("tEXt", [0]), PNGTestFixture.chunk("IDAT", [1])])]
    for value in values { #expect(throws: AgentError.self) { _ = try ChatGPTPNGStructure.parse(value) } }
  }

  @Test func animationNeverBecomesAStaticVerifiedImage() throws {
    let bytes = PNGTestFixture.framed(before: [PNGTestFixture.chunk("acTL", [0, 0, 0, 2, 0, 0, 0, 0])])
    #expect(try ChatGPTPNGStructure.parse(bytes).isAnimated)
    #expect(throws: AgentError.self) { _ = try ChatGPTImageArtifactInspector.inspect(bytes, requestedBackground: .auto, requestedSize: "auto") }
  }

  #if canImport(CoreGraphics) && canImport(ImageIO)
  @Test func framingDoesNotSubstituteForPixelDecode() throws {
    let malformedPixels = PNGTestFixture.framed(imageData: [1, 2, 3])
    #expect(try ChatGPTPNGStructure.parse(malformedPixels).width == 2)
    #expect(throws: AgentError.self) { _ = try ChatGPTImageArtifactInspector.inspect(malformedPixels, requestedBackground: .auto, requestedSize: "auto") }
  }

  @Test func asymmetricRowsAndColorsKeepOriginalCoordinates() throws {
    let expected: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0]
    let source = PNGTestFixture.png(width: 2, height: 2, rgba: expected)
    let raster = try ChatGPTImageRasterCodec.decode(source, requireLayerColorContract: true)
    #expect(raster.pixels == expected)
    let roundTrip = try ChatGPTImageRasterCodec.decode(ChatGPTImageRasterCodec.encode(raster), requireLayerColorContract: true)
    #expect(roundTrip == raster)
  }

  @Test func verificationScopeUsesActualAlphaAndNumericSize() throws {
    let bytes = PNGTestFixture.png()
    let accepted = try ChatGPTImageArtifactInspector.inspect(bytes, requestedBackground: .transparent, requestedSize: "02X01")
    #expect(accepted.status == .verified && accepted.transparency == .transparentPixelsPresent)
    #expect(accepted.mismatches.isEmpty)
    let rejected = try ChatGPTImageArtifactInspector.inspect(bytes, requestedBackground: .opaque, requestedSize: "3x1")
    #expect(rejected.status == .needsRepair)
    #expect(rejected.mismatches == ["size requested 3x1, observed 2x1",
      "opaque background requested, but decoded output contains transparent pixels"])
  }
  #endif
}
