import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

public enum ChatGPTImageTransparencyObservation: String, Codable, Hashable, Sendable {
  case transparentPixelsPresent = "transparent_pixels_present"
  case fullyOpaque = "fully_opaque"
  case unknown
}

public enum ChatGPTImageVerificationStatus: String, Codable, Hashable, Sendable {
  case verified
  case structuralOnly = "structural_only"
  case needsRepair = "needs_repair"
}

public struct ChatGPTImageVerification: Codable, Hashable, Sendable {
  public let width: Int
  public let height: Int
  public let contentSHA256: String
  public let transparency: ChatGPTImageTransparencyObservation
  public let status: ChatGPTImageVerificationStatus
  public let mismatches: [String]

  public init(
    width: Int,
    height: Int,
    contentSHA256: String,
    transparency: ChatGPTImageTransparencyObservation,
    status: ChatGPTImageVerificationStatus,
    mismatches: [String]
  ) {
    self.width = width
    self.height = height
    self.contentSHA256 = contentSHA256
    self.transparency = transparency
    self.status = status
    self.mismatches = mismatches
  }

  public var jsonValue: JSONValue {
    .object([
      "width": .integer(Int64(width)),
      "height": .integer(Int64(height)),
      "contentSHA256": .string(contentSHA256),
      "transparency": .string(transparency.rawValue),
      "status": .string(status.rawValue),
      "mismatches": .array(mismatches.map(JSONValue.string)),
    ])
  }
}

enum ChatGPTImageArtifactInspector {
  static func inspect(
    _ data: Data,
    requestedBackground: ChatGPTImageBackground,
    requestedSize: String
  ) throws -> ChatGPTImageVerification {
    let header = try ChatGPTPNGStructure.parse(data)
    guard !header.isAnimated else { throw AgentError.invalidToolCall("One static PNG is required") }
    let normalizedSize = try ChatGPTImageInputPolicy.size(requestedSize)
    let transparency: ChatGPTImageTransparencyObservation
    #if canImport(CoreGraphics) && canImport(ImageIO)
    // A down-converted 16-bit alpha plane cannot prove that all original samples were opaque.
    if header.bitDepth > 8 {
      transparency = .unknown
    } else {
      let raster = try ChatGPTImageRasterCodec.decode(data)
      transparency = raster.hasTransparentPixels ? .transparentPixelsPresent : .fullyOpaque
    }
    #else
    transparency = .unknown
    #endif
    var mismatches: [String] = []
    if normalizedSize != "auto", normalizedSize != "\(header.width)x\(header.height)" {
      mismatches.append("size requested \(normalizedSize), observed \(header.width)x\(header.height)")
    }
    switch (requestedBackground, transparency) {
    case (.transparent, .fullyOpaque):
      mismatches.append("transparent background requested, but decoded output is fully opaque")
    case (.opaque, .transparentPixelsPresent):
      mismatches.append("opaque background requested, but decoded output contains transparent pixels")
    default: break
    }
    let status: ChatGPTImageVerificationStatus
    if !mismatches.isEmpty { status = .needsRepair }
    else if transparency == .unknown { status = .structuralOnly }
    else { status = .verified }
    return ChatGPTImageVerification(
      width: header.width, height: header.height, contentSHA256: SHA256HexDigest.digest(data),
      transparency: transparency, status: status, mismatches: mismatches)
  }
}
