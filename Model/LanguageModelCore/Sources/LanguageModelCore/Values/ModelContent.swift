import Foundation

/// A binary input or output owned by a model message.
///
/// The bytes are explicit rather than an arbitrary URL so providers never gain
/// implicit access to the host filesystem or network. Large durable results
/// should instead be represented by host-owned artifacts.
public struct ModelBinaryContent: Codable, Sendable, Equatable, Hashable {
  public let mimeType: String
  public let data: Data
  public let filename: String?

  public init(mimeType: String, data: Data, filename: String? = nil) {
    self.mimeType = mimeType
    self.data = data
    self.filename = filename
  }
}

/// Provider-neutral model content. Providers must reject a part they cannot
/// encode; they must not silently turn media into a textual placeholder.
public enum ModelContentPart: Codable, Sendable, Equatable, Hashable {
  case text(String)
  case image(ModelBinaryContent)
  case audio(ModelBinaryContent)
  case file(ModelBinaryContent)

  public var text: String? {
    guard case .text(let value) = self else { return nil }
    return value
  }

  public var modality: ModelModality {
    switch self {
    case .text: .text
    case .image: .image
    case .audio: .audio
    case .file: .file
    }
  }

  private enum CodingKeys: String, CodingKey { case kind, text, binary }
  private enum Kind: String, Codable { case text, image, audio, file }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .text: self = .text(try container.decode(String.self, forKey: .text))
    case .image: self = .image(try container.decode(ModelBinaryContent.self, forKey: .binary))
    case .audio: self = .audio(try container.decode(ModelBinaryContent.self, forKey: .binary))
    case .file: self = .file(try container.decode(ModelBinaryContent.self, forKey: .binary))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try container.encode(Kind.text, forKey: .kind)
      try container.encode(value, forKey: .text)
    case .image(let value):
      try container.encode(Kind.image, forKey: .kind)
      try container.encode(value, forKey: .binary)
    case .audio(let value):
      try container.encode(Kind.audio, forKey: .kind)
      try container.encode(value, forKey: .binary)
    case .file(let value):
      try container.encode(Kind.file, forKey: .kind)
      try container.encode(value, forKey: .binary)
    }
  }
}

public enum ModelModality: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case text
  case image
  case audio
  case file
}

/// Stable capabilities used to reject impossible requests before a provider is
/// called and to select a route without provider-specific metadata parsing.
public struct ModelCapabilities: OptionSet, Codable, Sendable, Equatable, Hashable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) { self.rawValue = rawValue }

  public static let textInput = Self(rawValue: 1 << 0)
  public static let textOutput = Self(rawValue: 1 << 1)
  public static let imageInput = Self(rawValue: 1 << 2)
  public static let imageOutput = Self(rawValue: 1 << 3)
  public static let audioInput = Self(rawValue: 1 << 4)
  public static let audioOutput = Self(rawValue: 1 << 5)
  public static let fileInput = Self(rawValue: 1 << 6)
  public static let toolCalls = Self(rawValue: 1 << 7)
  public static let streaming = Self(rawValue: 1 << 8)
  public static let reasoning = Self(rawValue: 1 << 9)
  public static let fileOutput = Self(rawValue: 1 << 10)
  /// The provider enforces the requested structured-output schema rather than
  /// merely asking a text model to emit JSON.
  public static let structuredOutput = Self(rawValue: 1 << 11)

  public static let textOnly: Self = [.textInput, .textOutput]
  public static let allKnown: Self = [
    .textInput, .textOutput, .imageInput, .imageOutput,
    .audioInput, .audioOutput, .fileInput, .fileOutput,
    .toolCalls, .streaming, .reasoning, .structuredOutput,
  ]
}

public struct ModelDescriptor: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let providerID: String
  public let displayName: String?
  public let capabilities: ModelCapabilities
  public let contextWindowTokens: Int?

  public init(
    id: String,
    providerID: String,
    displayName: String? = nil,
    capabilities: ModelCapabilities = .textOnly,
    contextWindowTokens: Int? = nil
  ) {
    self.id = id
    self.providerID = providerID
    self.displayName = displayName
    self.capabilities = capabilities
    self.contextWindowTokens = contextWindowTokens
  }
}

public struct ModelUsage: Codable, Sendable, Equatable, Hashable {
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let totalTokens: Int?

  public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
  }
}
