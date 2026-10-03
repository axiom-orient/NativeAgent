@_spi(Service) import ChatGPTAccount
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Untrusted image endpoint wire encoding, bounded response collection, and PNG validation.
///
/// Authentication and retry policy intentionally remain in `ChatGPTImageClient`.
enum ChatGPTImageWireCodec {
  private enum Limits {
    static let maximumPromptUTF8Bytes = ChatGPTImageLimits.maximumPromptUTF8Bytes
    static let editRequestFixedOverheadBytes = 1_024
    static let encodedImageEnvelopeBytes = 64
    static let dimensionMultiple = 16
    static let maximumDimension = 3_840
    static let maximumAspectRatio = 3
    static let minimumPixelCount = 655_360
    static let maximumPixelCount = 8_294_400
  }

  static func encodeGenerationRequest(
    prompt: String,
    background: ChatGPTImageBackground,
    quality: ChatGPTImageQuality,
    size: String,
    model: String,
    maximumRequestBytes: Int
  ) throws -> Data {
    try validate(prompt: prompt, size: size)
    return try encode(
      [
        "prompt": prompt,
        "background": background.rawValue,
        "model": model,
        "quality": quality.rawValue,
        "size": size,
      ], maximumBytes: maximumRequestBytes)
  }

  static func encodeEditRequest(
    images: [ChatGPTImageContent],
    prompt: String,
    background: ChatGPTImageBackground,
    quality: ChatGPTImageQuality,
    size: String,
    model: String,
    maximumEditImages: Int,
    maximumInputImageBytes: Int,
    maximumRequestBytes: Int,
    maximumPNGPixelCount: Int,
    maximumPNGDecodedBytes: Int
  ) throws -> Data {
    try validate(prompt: prompt, size: size)
    guard (1...maximumEditImages).contains(images.count) else {
      throw ChatGPTImageFailure(.invalidRequest)
    }

    var estimatedBodyBytes = prompt.utf8.count + Limits.editRequestFixedOverheadBytes
    for image in images {
      guard image.mimeType.lowercased() == "image/png",
        image.data.count <= maximumInputImageBytes
      else { throw ChatGPTImageFailure(.invalidRequest) }
      let encodedBytes = ((image.data.count + 2) / 3) * 4
      let (next, overflow) = estimatedBodyBytes.addingReportingOverflow(
        encodedBytes + Limits.encodedImageEnvelopeBytes)
      guard !overflow, next <= maximumRequestBytes else {
        throw ChatGPTImageFailure(.limitExceeded)
      }
      estimatedBodyBytes = next
    }

    let imageURLs = try images.map { image -> [String: String] in
      try validatePNG(
        image.data,
        failure: .invalidRequest,
        maximumImageBytes: maximumInputImageBytes,
        maximumPNGPixelCount: maximumPNGPixelCount,
        maximumPNGDecodedBytes: maximumPNGDecodedBytes)
      return ["image_url": "data:image/png;base64,\(image.data.base64EncodedString())"]
    }
    return try encode(
      [
        "images": imageURLs,
        "prompt": prompt,
        "background": background.rawValue,
        "model": model,
        "quality": quality.rawValue,
        "size": size,
      ], maximumBytes: maximumRequestBytes)
  }

  static func response(
    transport: any ChatGPTTransport,
    request: URLRequest,
    maximumBytes: Int
  ) async throws -> (status: Int, headers: [String: String], body: Data) {
    try Task.checkCancellation()
    let operation = try await transport.invocation(request, maxResponseBytes: maximumBytes)
    return try await operation.consuming { stream in
      var status: Int?
      var headers: [String: String] = [:]
      var body = Data()
      for try await element in stream {
        try Task.checkCancellation()
        switch element {
        case .response(let value, let responseHeaders):
          guard status == nil, (100...599).contains(value) else {
            throw ChatGPTImageFailure(.malformedResponse)
          }
          status = value
          headers = responseHeaders
        case .body(let chunk):
          guard status != nil else { throw ChatGPTImageFailure(.malformedResponse) }
          let (next, overflow) = body.count.addingReportingOverflow(chunk.count)
          guard !overflow, next <= maximumBytes else {
            throw ChatGPTImageFailure(.limitExceeded)
          }
          body.append(chunk)
        }
      }
      try Task.checkCancellation()
      guard let status else { throw ChatGPTImageFailure(.malformedResponse) }
      return (status, headers, body)
    }
  }

  static func rejection(status: Int, headers: [String: String], body: Data) -> ChatGPTImageFailure {
    let responseCode = responseErrorCode(body)
    let responseReason = (status == 400 || status == 422) ? nil : responseErrorReason(body)
    let code: ChatGPTImageErrorCode
    switch status {
    case 400, 422:
      code = .invalidRequest
    case 401:
      code = .authenticationRequired
    case 413:
      code = .limitExceeded
    case 429:
      code = .rateLimited
    default:
      let normalizedCode = responseCode?.lowercased().replacingOccurrences(of: "-", with: "_")
      if let normalizedCode,
        (400..<500).contains(status),
        ["invalid_request", "invalid_request_error", "invalid_prompt", "invalid_image"].contains(normalizedCode)
      {
        code = .invalidRequest
      } else {
        code = .serviceRejected
      }
    }
    return ChatGPTImageFailure(
      code,
      httpStatusCode: status,
      requestID: requestID(headers),
      responseCode: responseCode,
      responseReason: responseReason)
  }

  static func requestID(_ headers: [String: String]) -> String? {
    let names = ["x-codex-imagegen-request-id", "x-request-id", "openai-request-id"]
    for name in names {
      guard let value = headers.first(where: {
        $0.key.caseInsensitiveCompare(name) == .orderedSame
      })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty, value.utf8.count <= 128,
        value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
      else { continue }
      return value
    }
    return nil
  }

  private static func responseErrorCode(_ body: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return nil
    }
    let nested = root["error"] as? [String: Any]
    guard let value = (nested?["code"] as? String) ?? (root["code"] as? String),
      (1...80).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ scalar in
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
          || (97...122).contains(scalar.value) || scalar.value == 45 || scalar.value == 95
          || scalar.value == 46
      })
    else { return nil }
    return value
  }

  /// Keep only a short printable explanation. The complete response body is untrusted and is never retained.
  private static func responseErrorReason(_ body: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return nil
    }
    let nested = root["error"] as? [String: Any]
    let value = (nested?["message"] as? String)
      ?? (root["message"] as? String)
      ?? (root["detail"] as? String)
    guard let value else { return nil }

    let printable = value.unicodeScalars.filter { scalar in
      scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value != 0x7F)
    }
    let normalized = String(String.UnicodeScalarView(printable))
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !normalized.isEmpty, normalized.utf8.count <= 160 else { return nil }
    return normalized
  }

  static func decodeResponse(
    _ data: Data,
    maximumImageBytes: Int,
    maximumPNGPixelCount: Int,
    maximumPNGDecodedBytes: Int
  ) throws -> ChatGPTImageResult {
    let response: WireResponse
    do {
      response = try JSONDecoder().decode(WireResponse.self, from: data)
    } catch {
      throw ChatGPTImageFailure(.malformedResponse)
    }

    let maximumBase64Bytes = ((maximumImageBytes + 2) / 3) * 4
    for item in response.data {
      guard let value = item.b64JSON else { continue }
      let encoded = trimCodexBase64Edges(value)
      guard !encoded.isEmpty, encoded.utf8.count <= maximumBase64Bytes,
        isStrictBase64(encoded),
        let bytes = Data(base64Encoded: encoded), bytes.count <= maximumImageBytes
      else { continue }
      do {
        try validatePNG(
          bytes,
          failure: .malformedResponse,
          maximumImageBytes: maximumImageBytes,
          maximumPNGPixelCount: maximumPNGPixelCount,
          maximumPNGDecodedBytes: maximumPNGDecodedBytes)
        return ChatGPTImageResult(
          image: ChatGPTImageContent(
            mimeType: "image/png", data: bytes, filename: "generated.png"),
          createdAt: Date(timeIntervalSince1970: TimeInterval(response.created)),
          background: response.background.flatMap(ChatGPTImageBackground.init(rawValue:)),
          quality: response.quality.flatMap(ChatGPTImageQuality.init(rawValue:)),
          size: response.size)
      } catch let failure as ChatGPTImageFailure where failure.code == .malformedResponse {
        continue
      }
    }
    throw ChatGPTImageFailure(.malformedResponse)
  }

  private struct WireResponse: Decodable {
    struct Image: Decodable {
      let b64JSON: String?

      private enum CodingKeys: String, CodingKey { case b64JSON = "b64_json" }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        b64JSON = try? container.decode(String.self, forKey: .b64JSON)
      }
    }

    let created: UInt64
    let data: [Image]
    let background: String?
    let quality: String?
    let size: String?

    private enum CodingKeys: String, CodingKey {
      case created, data, background, quality, size
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      created = try container.decode(UInt64.self, forKey: .created)
      data = try container.decode([Image].self, forKey: .data)
      // Optional metadata never decides whether otherwise valid image bytes are usable.
      background = try? container.decode(String.self, forKey: .background)
      quality = try? container.decode(String.self, forKey: .quality)
      size = try? container.decode(String.self, forKey: .size)
    }
  }

  private static func encode(_ body: [String: Any], maximumBytes: Int) throws -> Data {
    let encoded: Data
    do {
      guard JSONSerialization.isValidJSONObject(body) else {
        throw ChatGPTImageFailure(.invalidRequest)
      }
      encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    } catch {
      throw ChatGPTImageFailure(.invalidRequest)
    }
    guard encoded.count <= maximumBytes else {
      throw ChatGPTImageFailure(.limitExceeded)
    }
    return encoded
  }

  static func validatePrompt(_ prompt: String) throws {
    guard (1...Limits.maximumPromptUTF8Bytes).contains(prompt.utf8.count),
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !prompt.unicodeScalars.contains(where: { $0.value == 0 })
    else { throw ChatGPTImageFailure(.invalidRequest) }
  }

  private static func validate(prompt: String, size: String) throws {
    try validatePrompt(prompt)
    guard validSize(size) else { throw ChatGPTImageFailure(.invalidRequest) }
  }

  private static func validSize(_ value: String) -> Bool {
    if value == "auto" { return true }
    let parts = value.split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
      let width = Int(parts[0]), let height = Int(parts[1]),
      width > 0, height > 0,
      width.isMultiple(of: Limits.dimensionMultiple),
      height.isMultiple(of: Limits.dimensionMultiple),
      max(width, height) <= Limits.maximumDimension,
      max(width, height) <= min(width, height) * Limits.maximumAspectRatio
    else { return false }
    let pixels = width * height
    return (Limits.minimumPixelCount...Limits.maximumPixelCount).contains(pixels)
  }

  private static func isStrictBase64(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy {
      ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        || ($0.value >= 48 && $0.value <= 57) || $0.value == 43 || $0.value == 47
        || $0.value == 61
    }
  }

  /// Accepted transport whitespace used only around returned base64 payloads.
  /// Keeping the scalar list local avoids inheriting changing Swift/Rust runtime definitions of
  /// "whitespace" while still rejecting whitespace injected inside the payload.
  static let codexBase64EdgeWhitespaceScalars: [UInt32] =
    Array(0x0009...0x000D) + [0x0020, 0x0085, 0x00A0, 0x1680]
    + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  private static func trimCodexBase64Edges(_ value: String) -> String {
    let scalars = value.unicodeScalars
    var lower = scalars.startIndex
    while lower != scalars.endIndex, isCodexBase64EdgeWhitespace(scalars[lower]) {
      scalars.formIndex(after: &lower)
    }
    var upper = scalars.endIndex
    while upper != lower {
      let candidate = scalars.index(before: upper)
      guard isCodexBase64EdgeWhitespace(scalars[candidate]) else { break }
      upper = candidate
    }
    return String(scalars[lower..<upper])
  }

  private static func isCodexBase64EdgeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    codexBase64EdgeWhitespaceScalars.contains(scalar.value)
  }

  private static func validatePNG(
    _ data: Data,
    failure: ChatGPTImageErrorCode,
    maximumImageBytes: Int,
    maximumPNGPixelCount: Int,
    maximumPNGDecodedBytes: Int
  ) throws {
    func reject() throws { throw ChatGPTImageFailure(failure) }

    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard data.count >= 45, data.count <= maximumImageBytes, Array(data.prefix(8)) == signature
    else {
      try reject()
      return
    }
    var offset = 8
    var first = true
    var sawIDAT = false
    var sawIEND = false
    while offset < data.count {
      guard data.count - offset >= 12 else {
        try reject()
        return
      }
      let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
      let (chunkEnd, overflow) = offset.addingReportingOverflow(12 + length)
      guard !overflow, length <= maximumImageBytes, chunkEnd <= data.count else {
        try reject()
        return
      }
      let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
      if first {
        guard type == "IHDR", length == 13 else {
          try reject()
          return
        }
        let payload = offset + 8
        let width = data[payload..<payload + 4].reduce(0) { ($0 << 8) | Int($1) }
        let height = data[payload + 4..<payload + 8].reduce(0) { ($0 << 8) | Int($1) }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let bitDepth = data[payload + 8]
        let colorType = data[payload + 9]
        let validBitDepth: Bool
        let channels: Int
        switch colorType {
        case 0:
          channels = 1
          validBitDepth = [1, 2, 4, 8, 16].contains(bitDepth)
        case 2:
          channels = 3
          validBitDepth = [8, 16].contains(bitDepth)
        case 3:
          channels = 1
          validBitDepth = [1, 2, 4, 8].contains(bitDepth)
        case 4:
          channels = 2
          validBitDepth = [8, 16].contains(bitDepth)
        case 6:
          channels = 4
          validBitDepth = [8, 16].contains(bitDepth)
        default:
          channels = 0
          validBitDepth = false
        }
        let (rowSamples, rowSampleOverflow) = width.multipliedReportingOverflow(by: channels)
        let (rowBits, rowBitOverflow) = rowSamples.multipliedReportingOverflow(by: Int(bitDepth))
        let rowBytes = rowBits / 8 + (rowBits % 8 == 0 ? 0 : 1)
        let (filteredRowBytes, filterOverflow) = rowBytes.addingReportingOverflow(1)
        let (decodedBytes, decodedOverflow) = filteredRowBytes.multipliedReportingOverflow(
          by: height)
        guard (1...32_768).contains(width), (1...32_768).contains(height),
          !pixelOverflow, pixels <= maximumPNGPixelCount, validBitDepth,
          !rowSampleOverflow, !rowBitOverflow, !filterOverflow, !decodedOverflow,
          decodedBytes <= maximumPNGDecodedBytes,
          data[payload + 10] == 0, data[payload + 11] == 0, data[payload + 12] <= 1
        else {
          try reject()
          return
        }
        first = false
      } else if type == "IDAT" {
        sawIDAT = true
      } else if type == "IEND" {
        guard length == 0, chunkEnd == data.count else {
          try reject()
          return
        }
        sawIEND = true
      }
      offset = chunkEnd
    }
    guard !first, sawIDAT, sawIEND else {
      try reject()
      return
    }
  }
}
