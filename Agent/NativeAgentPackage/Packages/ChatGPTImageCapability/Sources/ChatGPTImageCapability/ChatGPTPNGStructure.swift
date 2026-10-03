import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
#if canImport(Compression)
import Compression
#endif

/// Bounded PNG framing admission, not a replacement for a PNG pixel decoder.
/// All size arithmetic is checked before ImageIO can allocate a decoded raster.
struct ChatGPTPNGStructure: Sendable {
  let width: Int
  let height: Int
  let bitDepth: UInt8
  let colorType: UInt8
  let alphaCapable: Bool
  let isAnimated: Bool
  let interlaceMethod: UInt8
  private let compressedImageData: Data

  static func parse(_ data: Data, maximumBytes: Int = ChatGPTImageClient.maximumImageBytes) throws -> Self {
    guard data.count >= 57, data.count <= maximumBytes else {
      throw invalid("PNG byte count is outside the admitted range")
    }
    return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
      guard signature.indices.allSatisfy({ bytes[$0] == signature[$0] }) else {
        throw invalid("Image result is not a PNG")
      }
      func uint32(_ start: Int) -> UInt32 {
        (start..<start + 4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[$1]) }
      }
      var offset = 8
      var header: (width: Int, height: Int, depth: UInt8, color: UInt8, interlace: UInt8)?
      var paletteEntryCount = 0
      var hasTransparency = false
      var animated = false
      var idatState = IDATState.before
      var compressedBytes = 0
      var compressedImageData = Data()
      while bytes.count - offset >= 12 {
        let rawLength = uint32(offset)
        guard rawLength <= 0x7fffffff, let length = Int(exactly: rawLength),
          length <= bytes.count - offset - 12 else {
          throw invalid("PNG chunk length exceeds the available bytes")
        }
        let payload = offset + 8
        let end = payload + length
        let typeBytes = Array(bytes[offset + 4..<payload])
        guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
          (65...90).contains(typeBytes[2]),
          crc32(bytes[offset + 4..<end]) == uint32(end) else {
          throw invalid("PNG chunk name or checksum is invalid")
        }
        let type = String(decoding: typeBytes, as: UTF8.self)
        guard header != nil || type == "IHDR" else { throw invalid("PNG must start with IHDR") }
        if idatState == .inside && type != "IDAT" { idatState = .after }
        switch type {
        case "IHDR":
          guard header == nil, offset == 8, length == 13 else { throw invalid("Invalid or duplicate PNG header") }
          guard let width = Int(exactly: uint32(payload)), let height = Int(exactly: uint32(payload + 4)) else {
            throw invalid("PNG dimensions cannot be represented")
          }
          try admitDimensions(width: width, height: height)
          let depth = bytes[payload + 8], color = bytes[payload + 9]
          let depths: [UInt8: Set<UInt8>] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
          guard depths[color]?.contains(depth) == true,
            bytes[payload + 10] == 0, bytes[payload + 11] == 0, bytes[payload + 12] <= 1 else {
            throw invalid("Unsupported PNG header encoding")
          }
          header = (width, height, depth, color, bytes[payload + 12])
        case "PLTE":
          guard let header, paletteEntryCount == 0, !hasTransparency, idatState == .before,
            header.color != 0, header.color != 4,
            (3...768).contains(length), length.isMultiple(of: 3),
            header.color != 3 || length / 3 <= (1 << Int(header.depth)) else {
            throw invalid("Invalid PNG palette")
          }
          paletteEntryCount = length / 3
        case "tRNS":
          guard let header, !hasTransparency, idatState == .before else { throw invalid("Invalid PNG transparency chunk") }
          switch header.color {
          case 0: guard length == 2 else { throw invalid("Invalid grayscale transparency") }
          case 2: guard length == 6 else { throw invalid("Invalid RGB transparency") }
          case 3: guard paletteEntryCount > 0, (1...paletteEntryCount).contains(length) else { throw invalid("Invalid palette transparency") }
          default: throw invalid("PNG alpha must not be duplicated by tRNS")
          }
          hasTransparency = true
        case "IDAT":
          guard let header, idatState != .after, header.color != 3 || paletteEntryCount > 0 else {
            throw invalid("PNG image chunks must be consecutive and follow their palette")
          }
          idatState = .inside
          compressedBytes += length // Bounded by maximumBytes, itself bounded by the caller.
          compressedImageData.append(contentsOf: bytes[payload..<end])
        case "IEND":
          guard let header, length == 0, compressedBytes > 0, end + 4 == bytes.count else {
            throw invalid("PNG is missing image data or has trailing bytes")
          }
          return Self(width: header.width, height: header.height, bitDepth: header.depth,
            colorType: header.color, alphaCapable: header.color == 4 || header.color == 6 || hasTransparency,
            isAnimated: animated, interlaceMethod: header.interlace,
            compressedImageData: compressedImageData)
        case "acTL", "fcTL", "fdAT":
          animated = true
        default:
          guard typeBytes[0] & 32 != 0 else { throw invalid("Unknown critical PNG chunk") }
        }
        offset = end + 4
      }
      throw invalid("PNG is truncated or missing IEND")
    }
  }

  /// Validates the bounded zlib/scanline payload before relying on ImageIO's rasterization.
  /// Some platform decoders can report a framed but truncated PNG as complete, so framing and
  /// pixel-stream admission remain separate checks.
  func validatePixelStream() throws {
    #if canImport(Compression)
    struct Pass {
      let width: Int
      let height: Int
    }

    let passes: [Pass]
    if interlaceMethod == 0 {
      passes = [Pass(width: width, height: height)]
    } else {
      let definitions = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8),
        (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
      passes = definitions.compactMap { x, y, dx, dy in
        guard width > x, height > y else { return nil }
        return Pass(
          width: (width - x + dx - 1) / dx,
          height: (height - y + dy - 1) / dy)
      }
    }

    let channels: Int
    switch colorType {
    case 0, 3: channels = 1
    case 2: channels = 3
    case 4: channels = 2
    case 6: channels = 4
    default:
      throw Self.invalid("Unsupported PNG color type")
    }
    let bitsPerPixel = channels.multipliedReportingOverflow(by: Int(bitDepth))
    guard !bitsPerPixel.overflow else { throw Self.invalid("PNG pixel bit count overflowed") }

    var rowBytesByPass: [Int] = []
    var expectedDecodedBytes = 0
    for pass in passes {
      let rowBits = pass.width.multipliedReportingOverflow(by: bitsPerPixel.partialValue)
      guard !rowBits.overflow else { throw Self.invalid("PNG row bit count overflowed") }
      let rowBytes = rowBits.partialValue / 8 + (rowBits.partialValue % 8 == 0 ? 0 : 1)
      let filteredRowBytes = rowBytes.addingReportingOverflow(1)
      guard !filteredRowBytes.overflow else { throw Self.invalid("PNG row byte count overflowed") }
      let passBytes = filteredRowBytes.partialValue.multipliedReportingOverflow(by: pass.height)
      guard !passBytes.overflow else { throw Self.invalid("PNG scanline byte count overflowed") }
      let total = expectedDecodedBytes.addingReportingOverflow(passBytes.partialValue)
      guard !total.overflow, total.partialValue <= ChatGPTImageClient.maximumPNGDecodedBytes else {
        throw Self.invalid("PNG scanlines exceed the decoded byte limit")
      }
      rowBytesByPass.append(rowBytes)
      expectedDecodedBytes = total.partialValue
    }
    guard expectedDecodedBytes > 0, !compressedImageData.isEmpty else {
      throw Self.invalid("PNG pixel stream is empty")
    }

    guard compressedImageData.count >= 6 else {
      throw Self.invalid("PNG zlib stream is truncated")
    }
    let compressionMethod = compressedImageData[compressedImageData.startIndex] & 0x0f
    let compressionInfo = compressedImageData[compressedImageData.startIndex] >> 4
    let flags = compressedImageData[compressedImageData.startIndex + 1]
    let zlibHeader = (Int(compressedImageData[compressedImageData.startIndex]) << 8)
      | Int(flags)
    guard compressionMethod == 8, compressionInfo <= 7, zlibHeader.isMultiple(of: 31),
      flags & 0x20 == 0 else {
      throw Self.invalid("PNG zlib header is invalid")
    }
    let deflate = Data(compressedImageData.dropFirst(2).dropLast(4))
    guard !deflate.isEmpty else { throw Self.invalid("PNG deflate stream is empty") }

    var decoded = [UInt8](repeating: 0, count: expectedDecodedBytes)
    let decodedCount = deflate.withUnsafeBytes { compressed in
      decoded.withUnsafeMutableBytes { output in
        compression_decode_buffer(
          output.bindMemory(to: UInt8.self).baseAddress!, output.count,
          compressed.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    guard decodedCount == expectedDecodedBytes else {
      throw Self.invalid("PNG pixel stream could not be completely decoded")
    }

    var adlerA: UInt32 = 1
    var adlerB: UInt32 = 0
    for byte in decoded {
      adlerA = (adlerA + UInt32(byte)) % 65_521
      adlerB = (adlerB + adlerA) % 65_521
    }
    let actualAdler = (adlerB << 16) | adlerA
    let expectedAdler = compressedImageData.suffix(4).reduce(UInt32(0)) {
      ($0 << 8) | UInt32($1)
    }
    guard actualAdler == expectedAdler else {
      throw Self.invalid("PNG zlib checksum is invalid")
    }

    var offset = 0
    for (pass, rowBytes) in zip(passes, rowBytesByPass) {
      for _ in 0..<pass.height {
        guard decoded[offset] <= 4 else { throw Self.invalid("PNG scanline filter is invalid") }
        offset += rowBytes + 1
      }
    }
    guard offset == decoded.count else { throw Self.invalid("PNG scanline payload length is invalid") }
    #endif
  }

  static func admitDimensions(width: Int, height: Int) throws {
    let pixels = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, width <= 0x7fffffff, height <= 0x7fffffff,
      !pixels.overflow, pixels.partialValue <= ChatGPTImageClient.maximumPNGPixelCount else {
      throw invalid("PNG dimensions exceed the decoded pixel limit")
    }
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
    guard !bytes.overflow, bytes.partialValue <= ChatGPTImageClient.maximumPNGDecodedBytes else {
      throw invalid("PNG exceeds the decoded RGBA byte limit")
    }
  }

  private enum IDATState: Equatable { case before, inside, after }

  static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
    var crc = UInt32.max
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
    return crc ^ UInt32.max
  }

  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = (crc & 1) == 0 ? crc >> 1 : 0xedb88320 ^ (crc >> 1) }
    return crc
  }

  private static func invalid(_ message: String) -> AgentError { .invalidToolCall(message) }
}
