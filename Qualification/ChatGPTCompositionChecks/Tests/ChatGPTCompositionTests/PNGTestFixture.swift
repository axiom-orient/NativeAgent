@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain
import LanguageModelCore

/// Small, independently encoded fixtures. Does not call production PNG/CRC/codec logic.
/// Fixtures use one uncompressed DEFLATE block, filter zero, straight RGBA8 and an sRGB chunk.
enum PNGTestFixture {
  static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  static let sourcePixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
  static let elementPixels: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0]

  static func png(width: Int = 2, height: Int = 1, rgba: [UInt8] = elementPixels) -> Data {
    precondition(width > 0 && height > 0 && width * height * 4 == rgba.count && rgba.count < 60_000)
    var scanlines: [UInt8] = []
    for row in 0..<height {
      scanlines.append(0)
      scanlines.append(contentsOf: rgba[(row * width * 4)..<((row + 1) * width * 4)])
    }
    let count = UInt16(scanlines.count)
    let inverse = ~count
    var zlib: [UInt8] = [0x78, 0x01, 0x01,
      UInt8(truncatingIfNeeded: count), UInt8(count >> 8),
      UInt8(truncatingIfNeeded: inverse), UInt8(inverse >> 8)]
    zlib += scanlines
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in scanlines { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
    zlib += be32((b << 16) | a)
    return framed(width: UInt32(width), height: UInt32(height), imageData: zlib)
  }

  static func framed(width: UInt32 = 2, height: UInt32 = 1, depth: UInt8 = 8,
    color: UInt8 = 6, before: [[UInt8]] = [], imageData: [UInt8] = [1],
    after: [[UInt8]] = [], includeEnd: Bool = true) -> Data {
    var bytes = signature + chunk("IHDR", be32(width) + be32(height) + [depth, color, 0, 0, 0])
    bytes += chunk("sRGB", [0])
    for value in before { bytes += value }
    bytes += chunk("IDAT", imageData)
    for value in after { bytes += value }
    if includeEnd { bytes += chunk("IEND", []) }
    return Data(bytes)
  }

  static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let contents = Array(type.utf8) + payload
    var crc: UInt32 = 0xffff_ffff
    for byte in contents {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        if (crc & 1) != 0 { crc = (crc >> 1) ^ 0xedb8_8320 } else { crc >>= 1 }
      }
    }
    return be32(UInt32(payload.count)) + contents + be32(crc ^ 0xffff_ffff)
  }

  static func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
  }

  static func image(_ bytes: Data? = nil) -> ModelBinaryContent {
    ModelBinaryContent(mimeType: "image/png", data: bytes ?? png(rgba: sourcePixels), filename: "source.png")
  }

  static func response(_ bytes: Data? = nil, mime: String = "image/png") -> ChatGPTImageResult {
    ChatGPTImageResult(image: .init(mimeType: mime, data: bytes ?? png(), filename: "result.png"),
      createdAt: Date(timeIntervalSince1970: 123), background: .transparent, quality: .high,
      size: "2x1", imageGenerationRequestID: "fixture-request-id")
  }

  static func context(root: URL = FileManager.default.temporaryDirectory) -> ToolExecutionContext {
    ToolExecutionContext(sessionID: "layer-tests", sessionDirectoryURL: root.appendingPathComponent("sessions/layer-tests"),
      sandboxRootURL: root)
  }

  static func inline(_ bytes: Data? = nil) -> JSONValue {
    .object(["mime_type": .string("image/png"), "base64": .string((bytes ?? png()).base64EncodedString())])
  }
}

/// Contract probe only. It proves request/result routing when tests run, not provider availability.
actor ImageServiceProbe: ChatGPTImageServing {
  enum Behavior: Sendable {
    case returns(ChatGPTImageResult)
    case fails(ChatGPTImageFailure)
    case cancelsThenReturns(ChatGPTImageResult)
  }
  let behavior: Behavior
  private(set) var edits: [ChatGPTImageEditRequest] = []
  private(set) var generations: [ChatGPTImageGenerationRequest] = []
  init(_ behavior: Behavior = .returns(PNGTestFixture.response())) { self.behavior = behavior }
  func edit(_ request: ChatGPTImageEditRequest) async throws -> ChatGPTImageResult {
    edits.append(request)
    return try respond()
  }
  func generate(_ request: ChatGPTImageGenerationRequest) async throws -> ChatGPTImageResult {
    generations.append(request)
    return try respond()
  }
  private func respond() throws -> ChatGPTImageResult {
    switch behavior {
    case .returns(let result): return result
    case .fails(let error): throw error
    case .cancelsThenReturns(let result):
      withUnsafeCurrentTask { $0?.cancel() }
      return result
    }
  }
}
