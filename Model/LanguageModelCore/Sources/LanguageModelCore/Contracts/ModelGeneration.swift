import Foundation

struct DurableDuration: Codable, Hashable, Sendable {
  let seconds: Int64
  let attoseconds: Int64

  init(_ duration: Duration) {
    let components = duration.components
    seconds = components.seconds
    attoseconds = components.attoseconds
  }

  var value: Duration {
    Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
  }
}

public enum ModelGenerationErrorCode: String, Codable, Hashable, Sendable {
  case invalidRequest
  case authenticationRequired
  case sourceUnavailable
  case limitExceeded
  case cancelled
  case deadlineExceeded
  case transportFailure
  case malformedEvent
  case terminalMissing
  case duplicateTerminal
  case policyViolation
}

/// Stable failure vocabulary at the model boundary. Provider diagnostics are
/// deliberately normalized before they reach durable agent state.
public struct ModelGenerationFailure: ModelClientFailure, Codable, Hashable, Sendable {
  public static let maximumMessageUTF8Bytes = 4 * 1_024

  public let code: ModelGenerationErrorCode
  public let message: String

  public init(_ code: ModelGenerationErrorCode, _ message: String) {
    self.code = code
    self.message = Self.bounded(message)
  }

  public var errorDescription: String? { "\(code.rawValue): \(message)" }
  public var modelFailureCode: String { code.rawValue }
  public var modelFailureDetails: [String: JSONValue] { [:] }

  private static func bounded(_ value: String) -> String {
    var bytes = Array(value.utf8.prefix(Self.maximumMessageUTF8Bytes))
    // A valid String prefix can be incomplete only in its last UTF-8 scalar.
    // Retain complete multibyte scalars and remove at most the partial suffix.
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
      bytes.removeLast()
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// Output semantics required by a request. A schema is an explicit core
/// contract instead of an adapter-specific metadata key.
public enum ModelOutputFormat: Codable, Hashable, Sendable {
  case text
  case jsonObject(schema: JSONValue)

  public func validate() throws {
    if case .jsonObject(let schema) = self {
      let byteCount: Int
      do {
        try schema.validateStructure(limits: ModelGenerationLimits.jsonStructureLimits)
        byteCount = try schema.canonicalUTF8ByteCount()
      } catch {
        throw ModelGenerationFailure(
          .invalidRequest,
          "Structured output schema must be valid finite JSON."
        )
      }
      guard schema.objectValue != nil, byteCount <= ModelGenerationLimits.maximumOutputSchemaUTF8Bytes else {
        throw ModelGenerationFailure(
          .invalidRequest,
          "Structured output schema must be one bounded JSON object."
        )
      }
    }
  }
}

/// Resource bounds shared by every model adapter. Providers may impose
/// narrower limits, but cannot silently widen these caller-owned bounds.
public struct ModelGenerationLimits: Codable, Hashable, Sendable {
  public static let standardVersion = "v1"
  public static let standardMaxMessages = 32
  public static let standardMaxMessageBytes = 16 * 1_024
  public static let standardMaxInputBytes = 128 * 1_024
  public static let standardMaxBinaryParts = 8
  public static let standardMaxBinaryInputBytes = 16 * 1_024 * 1_024
  public static let standardMaxBinaryOutputParts = 8
  public static let standardMaxBinaryOutputBytes = 32 * 1_024 * 1_024
  public static let standardMaxOutputBytes = 16 * 1_024
  public static let standardMaxDeltaBytes = 4 * 1_024
  public static let standardMaxFrameBytes = 64 * 1_024
  public static let standardMaxDeadline: Duration = .seconds(30)

  public static let supportedMaximumMessages = 64
  public static let supportedMaximumMessageBytes = 64 * 1_024
  public static let supportedMaximumInputBytes = 512 * 1_024
  public static let supportedMaximumBinaryParts = 16
  public static let supportedMaximumBinaryBytes = 64 * 1_024 * 1_024
  public static let supportedMaximumOutputBytes = 64 * 1_024
  public static let supportedMaximumDeltaBytes = 16 * 1_024
  public static let supportedMaximumFrameBytes = 256 * 1_024
  public static let supportedMaximumDeadline: Duration = .seconds(120)
  public static let maximumOutputSchemaUTF8Bytes = 64 * 1_024

  static let jsonStructureLimits = JSONValueStructureLimits(
    maximumDepth: 16,
    maximumNodes: 4_096,
    maximumCollectionEntries: 1_024,
    maximumStringUTF8Bytes: 64 * 1_024,
    maximumKeyUTF8Bytes: 256,
    maximumTotalStringUTF8Bytes: 128 * 1_024
  )

  public let version: String
  public let maxMessages: Int
  public let maxMessageBytes: Int
  public let maxInputBytes: Int
  public let maxBinaryParts: Int
  public let maxBinaryInputBytes: Int
  public let maxBinaryOutputParts: Int
  public let maxBinaryOutputBytes: Int
  public let maxOutputBytes: Int
  public let maxDeltaBytes: Int
  public let maxFrameBytes: Int
  public let maxDeadline: Duration

  public static let `default` = try! Self()

  public init(
    version: String = Self.standardVersion,
    maxMessages: Int = Self.standardMaxMessages,
    maxMessageBytes: Int = Self.standardMaxMessageBytes,
    maxInputBytes: Int = Self.standardMaxInputBytes,
    maxBinaryParts: Int = Self.standardMaxBinaryParts,
    maxBinaryInputBytes: Int = Self.standardMaxBinaryInputBytes,
    maxBinaryOutputParts: Int = Self.standardMaxBinaryOutputParts,
    maxBinaryOutputBytes: Int = Self.standardMaxBinaryOutputBytes,
    maxOutputBytes: Int = Self.standardMaxOutputBytes,
    maxDeltaBytes: Int = Self.standardMaxDeltaBytes,
    maxFrameBytes: Int = Self.standardMaxFrameBytes,
    maxDeadline: Duration = Self.standardMaxDeadline
  ) throws {
    guard version == Self.standardVersion,
      (0...Self.supportedMaximumMessages).contains(maxMessages),
      (1...Self.supportedMaximumMessageBytes).contains(maxMessageBytes),
      (1...Self.supportedMaximumInputBytes).contains(maxInputBytes),
      (0...Self.supportedMaximumBinaryParts).contains(maxBinaryParts),
      (1...Self.supportedMaximumBinaryBytes).contains(maxBinaryInputBytes),
      (0...Self.supportedMaximumBinaryParts).contains(maxBinaryOutputParts),
      (1...Self.supportedMaximumBinaryBytes).contains(maxBinaryOutputBytes),
      (1...Self.supportedMaximumOutputBytes).contains(maxOutputBytes),
      (1...Self.supportedMaximumDeltaBytes).contains(maxDeltaBytes),
      (1...Self.supportedMaximumFrameBytes).contains(maxFrameBytes),
      maxDeadline > .zero, maxDeadline <= Self.supportedMaximumDeadline
    else {
      throw ModelGenerationFailure(.limitExceeded, "Model limits exceed v1 absolute bounds.")
    }
    self.version = version
    self.maxMessages = maxMessages
    self.maxMessageBytes = maxMessageBytes
    self.maxInputBytes = maxInputBytes
    self.maxBinaryParts = maxBinaryParts
    self.maxBinaryInputBytes = maxBinaryInputBytes
    self.maxBinaryOutputParts = maxBinaryOutputParts
    self.maxBinaryOutputBytes = maxBinaryOutputBytes
    self.maxOutputBytes = maxOutputBytes
    self.maxDeltaBytes = maxDeltaBytes
    self.maxFrameBytes = maxFrameBytes
    self.maxDeadline = maxDeadline
  }

  private enum CodingKeys: String, CodingKey {
    case version, maxMessages, maxMessageBytes, maxInputBytes
    case maxBinaryParts, maxBinaryInputBytes, maxBinaryOutputParts, maxBinaryOutputBytes
    case maxOutputBytes
    case maxDeltaBytes, maxFrameBytes, maxDeadline
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      version: container.decode(String.self, forKey: .version),
      maxMessages: container.decode(Int.self, forKey: .maxMessages),
      maxMessageBytes: container.decode(Int.self, forKey: .maxMessageBytes),
      maxInputBytes: container.decode(Int.self, forKey: .maxInputBytes),
      maxBinaryParts: container.decode(Int.self, forKey: .maxBinaryParts),
      maxBinaryInputBytes: container.decode(Int.self, forKey: .maxBinaryInputBytes),
      maxBinaryOutputParts: container.decode(Int.self, forKey: .maxBinaryOutputParts),
      maxBinaryOutputBytes: container.decode(Int.self, forKey: .maxBinaryOutputBytes),
      maxOutputBytes: container.decode(Int.self, forKey: .maxOutputBytes),
      maxDeltaBytes: container.decode(Int.self, forKey: .maxDeltaBytes),
      maxFrameBytes: container.decode(Int.self, forKey: .maxFrameBytes),
      maxDeadline: container.decode(DurableDuration.self, forKey: .maxDeadline).value
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(maxMessages, forKey: .maxMessages)
    try container.encode(maxMessageBytes, forKey: .maxMessageBytes)
    try container.encode(maxInputBytes, forKey: .maxInputBytes)
    try container.encode(maxBinaryParts, forKey: .maxBinaryParts)
    try container.encode(maxBinaryInputBytes, forKey: .maxBinaryInputBytes)
    try container.encode(maxBinaryOutputParts, forKey: .maxBinaryOutputParts)
    try container.encode(maxBinaryOutputBytes, forKey: .maxBinaryOutputBytes)
    try container.encode(maxOutputBytes, forKey: .maxOutputBytes)
    try container.encode(maxDeltaBytes, forKey: .maxDeltaBytes)
    try container.encode(maxFrameBytes, forKey: .maxFrameBytes)
    try container.encode(DurableDuration(maxDeadline), forKey: .maxDeadline)
  }

  /// Splits text into non-empty UTF-8-valid deltas. Joining the result
  /// reproduces the input exactly.
  public func boundedDeltas(for text: String) throws -> [String] {
    guard !text.isEmpty else { return [] }
    var result: [String] = []
    var current: [UInt8] = []
    current.reserveCapacity(maxDeltaBytes)
    for scalar in text.unicodeScalars {
      let encoded = Array(String(scalar).utf8)
      guard encoded.count <= maxDeltaBytes else {
        throw ModelGenerationFailure(
          .limitExceeded,
          "A Unicode scalar exceeds the model delta byte limit."
        )
      }
      if current.count + encoded.count > maxDeltaBytes {
        result.append(String(decoding: current, as: UTF8.self))
        current.removeAll(keepingCapacity: true)
      }
      current.append(contentsOf: encoded)
    }
    if !current.isEmpty { result.append(String(decoding: current, as: UTF8.self)) }
    return result
  }
}

extension ModelUsage {
  public func validate() throws {
    for value in [inputTokens, outputTokens, totalTokens].compactMap({ $0 }) {
      guard value >= 0 else {
        throw ModelGenerationFailure(.malformedEvent, "Token usage is invalid.")
      }
    }
    if let inputTokens, let outputTokens, let totalTokens {
      let (sum, overflow) = inputTokens.addingReportingOverflow(outputTokens)
      guard !overflow, sum == totalTokens else {
        throw ModelGenerationFailure(.malformedEvent, "Token usage is invalid.")
      }
    }
  }
}

extension ModelTurn {
  public func validateGenerationContract(for request: ModelRequest) throws {
    try usage?.validate()
    guard content.utf8.count <= request.maxOutputBytes else {
      throw ModelGenerationFailure(.limitExceeded, "Model output exceeds the byte limit.")
    }

    var binaryParts = 0
    var binaryBytes = 0
    for part in contentParts {
      switch part {
      case .text:
        break
      case .image(let value):
        try validateBinaryOutput(
          value, required: .imageOutput, request: request,
          parts: &binaryParts, bytes: &binaryBytes)
      case .audio(let value):
        try validateBinaryOutput(
          value, required: .audioOutput, request: request,
          parts: &binaryParts, bytes: &binaryBytes)
      case .file(let value):
        try validateBinaryOutput(
          value, required: .fileOutput, request: request,
          parts: &binaryParts, bytes: &binaryBytes)
      }
    }

    guard toolCalls.count <= ModelToolContract.maximumCallsPerTurn else {
      throw ModelGenerationFailure(.limitExceeded, "Model tool-call count exceeds the limit.")
    }
    var auxiliaryBytes = reasoningSummary?.utf8.count ?? 0
    if let responseID {
      guard ModelRequest.validID(responseID) else {
        throw ModelGenerationFailure(.malformedEvent, "Model response identity is invalid.")
      }
      auxiliaryBytes = try add(
        responseID.utf8.count, to: auxiliaryBytes, maximum: request.maxOutputBytes)
    }
    var callIDs: Set<String> = []
    for call in toolCalls {
      guard ModelRequest.validID(call.id), ModelRequest.validToolName(call.name),
        callIDs.insert(call.id).inserted
      else {
        throw ModelGenerationFailure(.malformedEvent, "Model tool-call identity is invalid.")
      }
      do {
        try call.arguments.validateStructure(limits: ModelGenerationLimits.jsonStructureLimits)
        try JSONValue.object(call.metadata).validateStructure(
          limits: ModelGenerationLimits.jsonStructureLimits)
        auxiliaryBytes = try add(
          call.id.utf8.count + call.name.utf8.count,
          to: auxiliaryBytes,
          maximum: request.maxOutputBytes)
        auxiliaryBytes = try add(
          call.arguments.canonicalUTF8ByteCount(),
          to: auxiliaryBytes,
          maximum: request.maxOutputBytes)
        auxiliaryBytes = try add(
          JSONValue.object(call.metadata).canonicalUTF8ByteCount(),
          to: auxiliaryBytes,
          maximum: request.maxOutputBytes)
      } catch let failure as ModelGenerationFailure {
        throw failure
      } catch {
        throw ModelGenerationFailure(.malformedEvent, "Model tool-call arguments are invalid.")
      }
    }
    if !metadata.isEmpty {
      do {
        let value = JSONValue.object(metadata)
        try value.validateStructure(limits: ModelGenerationLimits.jsonStructureLimits)
        auxiliaryBytes = try add(
          value.canonicalUTF8ByteCount(), to: auxiliaryBytes, maximum: request.maxOutputBytes)
      } catch let failure as ModelGenerationFailure {
        throw failure
      } catch {
        throw ModelGenerationFailure(.malformedEvent, "Model metadata is invalid.")
      }
    }
    guard auxiliaryBytes <= request.maxOutputBytes else {
      throw ModelGenerationFailure(.limitExceeded, "Model auxiliary output exceeds the byte limit.")
    }
  }

  private func validateBinaryOutput(
    _ value: ModelBinaryContent,
    required capability: ModelCapabilities,
    request: ModelRequest,
    parts: inout Int,
    bytes: inout Int
  ) throws {
    guard request.requiredCapabilities.contains(capability) else {
      throw ModelGenerationFailure(.policyViolation, "Model emitted an undeclared binary output.")
    }
    try value.validateGenerationContract()
    parts += 1
    let (sum, overflow) = bytes.addingReportingOverflow(value.data.count)
    guard !overflow,
      parts <= request.limits.maxBinaryOutputParts,
      sum <= request.limits.maxBinaryOutputBytes
    else {
      throw ModelGenerationFailure(
        .limitExceeded, "Model binary output exceeds the declared limits.")
    }
    bytes = sum
  }

  private func add(_ addition: Int, to current: Int, maximum: Int) throws -> Int {
    let (sum, overflow) = current.addingReportingOverflow(addition)
    guard !overflow, sum <= maximum else {
      throw ModelGenerationFailure(.limitExceeded, "Model auxiliary output exceeds the byte limit.")
    }
    return sum
  }
}
