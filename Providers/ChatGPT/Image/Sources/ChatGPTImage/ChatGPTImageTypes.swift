import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum ChatGPTImageBackground: String, Codable, Hashable, Sendable {
  case transparent
  case opaque
  case auto
}

public enum ChatGPTImageQuality: String, Codable, Hashable, Sendable {
  case low
  case medium
  case high
  case auto
}

public struct ChatGPTImageGenerationRequest: Hashable, Sendable {
  public let prompt: String
  public let background: ChatGPTImageBackground
  public let quality: ChatGPTImageQuality
  public let size: String
  public let turnID: UUID

  public init(
    prompt: String,
    background: ChatGPTImageBackground = .auto,
    quality: ChatGPTImageQuality = .auto,
    size: String = "auto",
    turnID: UUID = UUID()
  ) {
    self.prompt = prompt
    self.background = background
    self.quality = quality
    self.size = size
    self.turnID = turnID
  }
}

public struct ChatGPTImageEditRequest: Hashable, Sendable {
  public let images: [ChatGPTImageContent]
  public let prompt: String
  public let background: ChatGPTImageBackground
  public let quality: ChatGPTImageQuality
  public let size: String
  public let turnID: UUID

  public init(
    images: [ChatGPTImageContent],
    prompt: String,
    background: ChatGPTImageBackground = .auto,
    quality: ChatGPTImageQuality = .auto,
    size: String = "auto",
    turnID: UUID = UUID()
  ) {
    self.images = images
    self.prompt = prompt
    self.background = background
    self.quality = quality
    self.size = size
    self.turnID = turnID
  }
}

/// Provider-observed image result. Caller intent remains owned by the request/tool layer.
public struct ChatGPTImageResult: Hashable, Sendable {
  public let image: ChatGPTImageContent
  public let createdAt: Date
  public let background: ChatGPTImageBackground?
  public let quality: ChatGPTImageQuality?
  public let size: String?
  /// Server correlation evidence. It is not an idempotency or exactly-once key.
  public let imageGenerationRequestID: String?

  public init(
    image: ChatGPTImageContent,
    createdAt: Date,
    background: ChatGPTImageBackground? = nil,
    quality: ChatGPTImageQuality? = nil,
    size: String? = nil,
    imageGenerationRequestID: String? = nil
  ) {
    self.image = image
    self.createdAt = createdAt
    self.background = background
    self.quality = quality
    self.size = size
    self.imageGenerationRequestID = imageGenerationRequestID
  }
}

public enum ChatGPTImageErrorCode: String, Codable, Hashable, Sendable {
  case invalidRequest
  case authenticationRequired
  case rateLimited
  case serviceRejected
  case malformedResponse
  case limitExceeded
  case cancelled
  case transportFailure
}

public struct ChatGPTImageFailure: Error, Codable, Hashable, Sendable, LocalizedError {
  public let code: ChatGPTImageErrorCode
  public let message: String
  public let httpStatusCode: Int?
  public let requestID: String?
  public let responseCode: String?
  public let responseReason: String?

  public init(
    _ code: ChatGPTImageErrorCode,
    httpStatusCode: Int? = nil,
    requestID: String? = nil,
    responseCode: String? = nil,
    responseReason: String? = nil
  ) {
    self.code = code
    self.httpStatusCode = httpStatusCode
    self.requestID = requestID
    self.responseCode = responseCode
    self.responseReason = responseReason
    switch code {
    case .invalidRequest: message = "The image request is invalid."
    case .authenticationRequired: message = "Sign in with ChatGPT is required."
    case .rateLimited: message = "The ChatGPT image usage limit was reached."
    case .serviceRejected: message = "The ChatGPT image service rejected the request."
    case .malformedResponse: message = "The ChatGPT image service returned an invalid response."
    case .limitExceeded: message = "The image request or response exceeded its limit."
    case .cancelled: message = "Image generation was cancelled."
    case .transportFailure: message = "The ChatGPT image service could not be reached."
    }
  }

  public var errorDescription: String? { "\(code.rawValue): \(message)" }

  public var diagnosticDescription: String? {
    var parts: [String] = []
    if let httpStatusCode { parts.append("HTTP \(httpStatusCode)") }
    if let responseCode { parts.append("code \(responseCode)") }
    if let responseReason { parts.append("reason \(responseReason)") }
    if let requestID { parts.append("request ID \(requestID)") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// Raw image payload. Agent adapters convert at their boundary; no model runtime is required.
public struct ChatGPTImageContent: Hashable, Sendable {
  public let mimeType: String
  public let data: Data
  public let filename: String?

  public init(mimeType: String, data: Data, filename: String? = nil) {
    self.mimeType = mimeType
    self.data = data
    self.filename = filename
  }
}
