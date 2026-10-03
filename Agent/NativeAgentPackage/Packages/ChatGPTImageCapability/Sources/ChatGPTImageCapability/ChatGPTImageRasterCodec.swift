import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Apple codec adapter. No network, file writes, thumbnails, resampling or implicit orientation fixes.
enum ChatGPTImageRasterCodec {
  static func decode(
    _ data: Data,
    maximumBytes: Int = ChatGPTImageClient.maximumImageBytes,
    requireLayerColorContract: Bool = false
  ) throws -> ChatGPTLayerRaster {
    let header = try ChatGPTPNGStructure.parse(data, maximumBytes: maximumBytes)
    guard !header.isAnimated else { throw AgentError.invalidToolCall("One static PNG is required") }
    #if canImport(CoreGraphics) && canImport(ImageIO)
    try header.validatePixelStream()
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    let decodeOptions = [kCGImageSourceShouldCache: true,
      kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetCount(source) == 1,
      let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions),
      image.width == header.width, image.height == header.height,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
      throw AgentError.invalidToolCall("PNG pixels could not be completely decoded")
    }
    if requireLayerColorContract {
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      guard orientation == 1, header.bitDepth == 8,
        header.colorType == 2 || header.colorType == 6,
        image.colorSpace?.name == CGColorSpace.sRGB else {
        throw AgentError.invalidToolCall(
          "Layer input requires orientation 1, 8-bit RGB/RGBA and sRGB; normalize explicitly in the host")
      }
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw AgentError.unsupportedSurface("sRGB is unavailable")
    }
    var pixels = [UInt8](repeating: 0, count: header.width * header.height * 4)
    let decoded = pixels.withUnsafeMutableBytes { storage -> Bool in
      guard let context = CGContext(
        data: storage.baseAddress, width: header.width, height: header.height,
        bitsPerComponent: 8, bytesPerRow: header.width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.setBlendMode(.copy)
      context.interpolationQuality = .none
      // A bitmap's first row is the image's top row. No UIKit coordinate transform is applied.
      context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(header.width), height: CGFloat(header.height)))
      return true
    }
    guard decoded else { throw AgentError.unsupportedSurface("Cannot allocate a bounded RGBA context") }
    guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
      throw AgentError.invalidToolCall("PNG decoding did not complete")
    }
    return try ChatGPTLayerRaster(width: header.width, height: header.height, pixels: pixels)
    #else
    throw AgentError.unsupportedSurface("PNG pixel decoding requires ImageIO and CoreGraphics")
    #endif
  }

  static func encode(_ raster: ChatGPTLayerRaster) throws -> Data {
    #if canImport(CoreGraphics) && canImport(ImageIO)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let provider = CGDataProvider(data: Data(raster.pixels) as CFData),
      let image = CGImage(
        width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: raster.width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
      ) else { throw AgentError.unsupportedSurface("Cannot create the output RGBA image") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
      throw AgentError.unsupportedSurface("PNG encoding is unavailable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), output.length <= ChatGPTImageClient.maximumImageBytes else {
      throw AgentError.invalidToolCall("PNG output could not be finalized within its byte limit")
    }
    return output as Data
    #else
    throw AgentError.unsupportedSurface("PNG pixel encoding requires ImageIO and CoreGraphics")
    #endif
  }
}
