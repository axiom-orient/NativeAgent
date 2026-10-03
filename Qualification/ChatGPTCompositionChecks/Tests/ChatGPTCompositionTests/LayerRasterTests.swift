@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Testing
import NativeAgentDomain

@Suite("Deterministic layer pixel contracts")
struct LayerRasterTests {
  @Test func clearPixelsAreExactlyTheSelectedKeyAndOpaqueSubjectIsUnchanged() throws {
    let input = try ChatGPTLayerRaster(width: 2, height: 1, pixels: [255, 0, 255, 255, 0, 0, 0, 0])
    let result = try input.chromaExport()
    #expect(result.key == .green)
    #expect(result.minimumSquaredRGBDistance == 132_835)
    #expect(result.raster.pixels == [255, 0, 255, 255, 0, 177, 64, 255])
    #expect(input.pixels == [255, 0, 255, 255, 0, 0, 0, 0])
  }

  @Test func greenSubjectChoosesMagenta() throws {
    let input = try ChatGPTLayerRaster(width: 2, height: 1, pixels: [0, 177, 64, 255, 0, 0, 0, 0])
    let result = try input.chromaExport()
    #expect(result.key == .magenta)
    #expect(result.raster.pixels == [0, 177, 64, 255, 255, 0, 255, 255])
  }

  @Test func collisionRequiresRGBAAndTieIsDeterministic() throws {
    let input = try ChatGPTLayerRaster(width: 3, height: 1,
      pixels: [0, 177, 64, 255, 255, 0, 255, 255, 0, 0, 0, 0])
    let result = try input.chromaExport()
    #expect(result.minimumSquaredRGBDistance == 0 && result.key == .green)
    #expect(try input.chromaExport().raster == result.raster)
  }

  @Test func partialAlphaBlendsOnlyThePixelAndPreservesWorkingAlpha() throws {
    let input = try ChatGPTLayerRaster(width: 2, height: 1, pixels: [128, 0, 0, 128, 0, 0, 0, 0])
    let output = try input.chromaExport()
    #expect(output.key == .green)
    #expect(output.raster.pixels == [128, 88, 32, 255, 0, 177, 64, 255])
    #expect(input.hasSubject && input.hasTransparentPixels && input.hasClearPixels)
    #expect(input.pixels[3] == 128)
  }

  @Test func clearPixelsDoNotParticipateInColorSelection() throws {
    let solid = try ChatGPTLayerRaster(width: 1, height: 1, pixels: [255, 0, 255, 255])
    let padded = try ChatGPTLayerRaster(width: 3, height: 1,
      pixels: [0, 0, 0, 0, 255, 0, 255, 255, 0, 0, 0, 0])
    #expect(try solid.chromaExport().key == padded.chromaExport().key)
    #expect(try solid.chromaExport().minimumSquaredRGBDistance == padded.chromaExport().minimumSquaredRGBDistance)
  }

  @Test func sourceOverUsesDeclaredOrderAndExactIntegerRounding() throws {
    let front = try ChatGPTLayerRaster(width: 2, height: 1, pixels: [128, 0, 0, 128, 0, 0, 0, 0])
    let back = try ChatGPTLayerRaster(width: 2, height: 1, pixels: [0, 0, 255, 255, 0, 255, 0, 255])
    #expect(try front.composited(over: back).pixels == [128, 0, 127, 255, 0, 255, 0, 255])
    #expect(try back.composited(over: front).pixels == back.pixels)
  }

  @Test func invalidRasterAndCanvasMismatchThrowInsteadOfClamping() throws {
    #expect(throws: AgentError.self) { _ = try ChatGPTLayerRaster(width: 1, height: 1, pixels: [0]) }
    #expect(throws: AgentError.self) { _ = try ChatGPTLayerRaster(width: 1, height: 1, pixels: [255, 0, 0, 128]) }
    let empty = try ChatGPTLayerRaster(width: 1, height: 1, pixels: [0, 0, 0, 0])
    #expect(!empty.hasSubject && empty.hasClearPixels)
    #expect(throws: AgentError.self) { _ = try empty.chromaExport() }
    let different = try ChatGPTLayerRaster(width: 2, height: 1, pixels: Array(repeating: 0, count: 8))
    #expect(throws: AgentError.self) { _ = try empty.composited(over: different) }
  }
}
