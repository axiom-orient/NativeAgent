import Foundation
import NativeAgentDomain

/// Row-major, top-left-origin, premultiplied RGBA8 in sRGB sample space.
/// This is an in-memory working representation, never the source-image authority.
struct ChatGPTLayerRaster: Sendable, Equatable {
  let width: Int
  let height: Int
  let pixels: [UInt8]

  init(width: Int, height: Int, pixels: [UInt8]) throws {
    try ChatGPTPNGStructure.admitDimensions(width: width, height: height)
    guard pixels.count == width * height * 4 else {
      throw AgentError.invalidToolCall("RGBA byte count does not match the canvas")
    }
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = pixels[offset + 3]
      guard pixels[offset] <= alpha, pixels[offset + 1] <= alpha, pixels[offset + 2] <= alpha else {
        throw AgentError.invalidToolCall("RGBA samples must be premultiplied")
      }
    }
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  var hasSubject: Bool { stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 } }
  var hasTransparentPixels: Bool { stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 } }
  var hasClearPixels: Bool { stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] == 0 } }

  enum ChromaKey: String, Codable, Sendable {
    case green = "#00B140"
    case magenta = "#FF00FF"
    var rgb: [UInt8] {
      switch self {
      case .green: [0, 177, 64]
      case .magenta: [255, 0, 255]
      }
    }
  }

  struct ChromaExport: Sendable {
    let raster: ChatGPTLayerRaster
    let key: ChromaKey
    let minimumSquaredRGBDistance: Int
  }

  /// Maximize the minimum squared distance to unassociated subject RGB samples.
  /// Ties choose green. This is a specified metric, not a perceptual-optimality claim.
  func chromaExport() throws -> ChromaExport {
    guard hasSubject else { throw AgentError.invalidToolCall("An empty layer cannot be exported") }
    let greenScore = minimumDistance(to: .green)
    let magentaScore = minimumDistance(to: .magenta)
    let key: ChromaKey = greenScore >= magentaScore ? .green : .magenta
    let color = key.rgb
    var output = pixels
    for offset in stride(from: 0, to: output.count, by: 4) {
      let inverseAlpha = 255 - Int(pixels[offset + 3])
      for channel in 0..<3 {
        output[offset + channel] = UInt8(Int(pixels[offset + channel]) +
          (Int(color[channel]) * inverseAlpha + 127) / 255)
      }
      output[offset + 3] = 255
    }
    return ChromaExport(
      raster: try Self(width: width, height: height, pixels: output), key: key,
      minimumSquaredRGBDistance: max(greenScore, magentaScore))
  }

  /// Exact, deterministic sample-space source-over. Order is back-to-front.
  /// Alpha sidecars, not a color-key heuristic, are required for this operation.
  func composited(over background: Self) throws -> Self {
    guard width == background.width, height == background.height else {
      throw AgentError.invalidToolCall("All layers must use the identical canvas")
    }
    var output = pixels
    for offset in stride(from: 0, to: output.count, by: 4) {
      let inverseAlpha = 255 - Int(pixels[offset + 3])
      for channel in 0..<4 {
        output[offset + channel] = UInt8(Int(pixels[offset + channel]) +
          (Int(background.pixels[offset + channel]) * inverseAlpha + 127) / 255)
      }
    }
    return try Self(width: width, height: height, pixels: output)
  }

  private func minimumDistance(to key: ChromaKey) -> Int {
    let rgb = key.rgb
    var minimum = 3 * 255 * 255
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Int(pixels[offset + 3])
      guard alpha > 0 else { continue }
      var distance = 0
      for channel in 0..<3 {
        let unassociated = (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha
        let delta = unassociated - Int(rgb[channel])
        distance += delta * delta
      }
      minimum = min(minimum, distance)
    }
    return minimum
  }
}
