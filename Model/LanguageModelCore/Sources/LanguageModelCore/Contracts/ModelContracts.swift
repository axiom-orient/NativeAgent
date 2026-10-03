import Foundation

/// Typed failure boundary for model-provider adapters.
///
/// Agent runtime depends on this protocol, not on any concrete provider
/// module, so provider-specific status and retry metadata can cross the
/// boundary without coupling durable execution to HTTP implementations.
public protocol ModelClientFailure: Error, LocalizedError, Sendable {
  var modelFailureCode: String { get }
  var modelFailureDetails: [String: JSONValue] { get }
}

public struct ModelInputFootprint: Sendable, Equatable {
  public let messageCount: Int
  public let inlineInputBytes: Int
  public let binaryPartCount: Int
  public let binaryInputBytes: Int
  public let aggregateInputBytes: Int

  init(
    messageCount: Int,
    inlineInputBytes: Int,
    binaryPartCount: Int,
    binaryInputBytes: Int
  ) throws {
    let (aggregateInputBytes, overflow) = inlineInputBytes.addingReportingOverflow(binaryInputBytes)
    guard messageCount >= 0, inlineInputBytes >= 0, binaryPartCount >= 0,
      binaryInputBytes >= 0, !overflow
    else {
      throw ModelGenerationFailure(.limitExceeded, "Model input footprint overflowed.")
    }
    self.messageCount = messageCount
    self.inlineInputBytes = inlineInputBytes
    self.binaryPartCount = binaryPartCount
    self.binaryInputBytes = binaryInputBytes
    self.aggregateInputBytes = aggregateInputBytes
  }
}

public enum ModelMessageContract {
  /// Typed content parts accepted by one historical/request message.
  public static let maximumContentPartsPerMessage = 32
}

public enum ModelToolContract {
  /// Tool definitions accepted by one model request.
  public static let maximumDefinitionCount = 32
  /// Tool calls retained in one historical message.
  public static let maximumCallsPerMessage = 32
  /// Tool calls retained across one request transcript.
  public static let maximumHistoricalCallsPerRequest = 32
  /// Tool calls accepted from one generated turn.
  public static let maximumCallsPerTurn = 32
  public static let maximumNameUTF8Bytes = 64
  public static let maximumDescriptionUTF8Bytes = 1_024

  public static func isValidName(_ value: String) -> Bool {
    (1...maximumNameUTF8Bytes).contains(value.utf8.count)
      && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57)
          || ($0.value >= 65 && $0.value <= 90)
          || ($0.value >= 97 && $0.value <= 122)
          || $0.value == 45 || $0.value == 46 || $0.value == 95
      }
  }
}

private enum ModelIdentityContract {
  static let maximumInternalIdentifierUTF8Bytes = 128
  static let maximumExternalIdentifierUTF8Bytes = 256
  static let maximumDisplayNameUTF8Bytes = 512
}

private enum ModelBinaryContentContract {
  static let minimumMIMETypeUTF8Bytes = 3
  static let maximumMIMETypeUTF8Bytes = 128
  static let maximumFilenameUTF8Bytes = 255
}

public struct ModelRequest: Codable, Sendable, Equatable {
  public let sessionID: String
  public let modelID: String?
  public let messages: [AgentMessage]
  public let tools: [ModelTool]
  public let metadata: [String: JSONValue]
  public let requiredCapabilities: ModelCapabilities
  public let outputFormat: ModelOutputFormat
  public let maxOutputBytes: Int
  public let deadline: Duration
  public let limits: ModelGenerationLimits

  public init(
    sessionID: String,
    modelID: String? = nil,
    messages: [AgentMessage],
    tools: [ModelTool],
    metadata: [String: JSONValue] = [:],
    requiredCapabilities: ModelCapabilities = .textOnly,
    outputFormat: ModelOutputFormat = .text,
    maxOutputBytes: Int? = nil,
    deadline: Duration? = nil,
    limits: ModelGenerationLimits = .default
  ) {
    self.sessionID = sessionID
    self.modelID = modelID
    self.messages = messages
    self.tools = tools
    self.metadata = metadata
    self.requiredCapabilities = requiredCapabilities
    self.outputFormat = outputFormat
    self.maxOutputBytes = maxOutputBytes ?? limits.maxOutputBytes
    self.deadline = deadline ?? limits.maxDeadline
    self.limits = limits
  }

  public func applying(_ event: ModelRequestEvent) -> ModelRequest {
    switch event {
    case .contentsChanged(let messages, let metadata):
      return ModelRequest(
        sessionID: sessionID,
        modelID: modelID,
        messages: messages,
        tools: tools,
        metadata: metadata,
        requiredCapabilities: requiredCapabilities,
        outputFormat: outputFormat,
        maxOutputBytes: maxOutputBytes,
        deadline: deadline,
        limits: limits
      )
    }
  }

  /// Requirements derived from the actual request always win over a caller's
  /// minimal declaration; routes cannot accidentally receive unsupported
  /// media or tool calls.
  public var effectiveRequiredCapabilities: ModelCapabilities {
    // Every invocation returns an authoritative textual turn. Callers may add
    // requirements, but they cannot weaken capabilities implied by the actual
    // request/output contract.
    var result = requiredCapabilities
    result.insert(.textOutput)
    for message in messages {
      for part in message.contentParts {
        switch part.modality {
        case .text: result.insert(.textInput)
        case .image: result.insert(.imageInput)
        case .audio: result.insert(.audioInput)
        case .file: result.insert(.fileInput)
        }
      }
    }
    if messages.contains(where: {
      $0.toolCallID != nil || $0.toolName != nil || !$0.toolCalls.isEmpty
    }) {
      result.insert(.toolCalls)
    }
    if !tools.isEmpty { result.insert(.toolCalls) }
    if case .jsonObject = outputFormat { result.insert(.structuredOutput) }
    return result
  }

  /// Providers which have not implemented a typed media encoder use this to
  /// reject input before transport rather than silently dropping it.
  public var containsNonTextContent: Bool {
    messages.contains { message in
      message.contentParts.contains { part in
        if case .text = part { return false }
        return true
      }
    }
  }

  public func validateSupportedCapabilities(_ supported: ModelCapabilities) throws {
    let required = effectiveRequiredCapabilities
    guard required.isSubset(of: supported) else {
      let missing = ModelCapabilities(rawValue: required.rawValue & ~supported.rawValue)
      throw ModelGenerationFailure(
        .policyViolation,
        "Model does not support required capabilities (missing mask: \(missing.rawValue))."
      )
    }
  }

  public func validateGenerationContract() throws {
    _ = try inputFootprint()
  }

  /// Validates the request and returns the exact footprint used by the same
  /// generation contract. Callers must not reimplement byte accounting.
  public func inputFootprint() throws -> ModelInputFootprint {
    guard Self.validID(sessionID),
      modelID.map(ModelContractIdentifier.isValidExternal) ?? true,
      requiredCapabilities.isSubset(of: .allKnown),
      !messages.isEmpty, messages.count <= limits.maxMessages,
      maxOutputBytes > 0, maxOutputBytes <= limits.maxOutputBytes,
      deadline > .zero, deadline <= limits.maxDeadline
    else {
      throw ModelGenerationFailure(
        .invalidRequest,
        "Model request is outside its declared limits."
      )
    }
    var inputBytes = 0
    var binaryBytes = 0
    var binaryParts = 0
    var messageToolCalls = 0
    for message in messages {
      guard Self.validID(message.id),
        message.createdAt.timeIntervalSinceReferenceDate.isFinite,
        !message.contentParts.isEmpty,
        message.contentParts.count <= ModelMessageContract.maximumContentPartsPerMessage,
        message.toolCallID.map(Self.validID) ?? true,
        message.toolName.map(Self.validToolName) ?? true,
        message.toolCalls.count <= ModelToolContract.maximumCallsPerMessage
      else {
        throw ModelGenerationFailure(.invalidRequest, "Model message identity is invalid.")
      }
      var messageBytes = message.id.utf8.count
      if let toolCallID = message.toolCallID {
        messageBytes = try Self.addMessageBytes(toolCallID.utf8.count, to: messageBytes)
      }
      if let toolName = message.toolName {
        messageBytes = try Self.addMessageBytes(toolName.utf8.count, to: messageBytes)
      }
      for part in message.contentParts {
        switch part {
        case .text(let value):
          let (sum, overflow) = messageBytes.addingReportingOverflow(value.utf8.count)
          guard !overflow else {
            throw ModelGenerationFailure(.limitExceeded, "Model input exceeds the byte limit.")
          }
          messageBytes = sum
        case .image(let value), .audio(let value), .file(let value):
          try value.validateGenerationContract()
          binaryParts += 1
          let (sum, overflow) = binaryBytes.addingReportingOverflow(value.data.count)
          guard !overflow else {
            throw ModelGenerationFailure(.limitExceeded, "Model media exceeds the byte limit.")
          }
          binaryBytes = sum
        }
      }
      var messageCallIDs: Set<String> = []
      for call in message.toolCalls {
        guard Self.validID(call.id), Self.validToolName(call.name),
          messageCallIDs.insert(call.id).inserted
        else {
          throw ModelGenerationFailure(.invalidRequest, "Model message tool call is invalid.")
        }
        messageToolCalls += 1
        guard messageToolCalls <= ModelToolContract.maximumHistoricalCallsPerRequest else {
          throw ModelGenerationFailure(
            .limitExceeded, "Model message tool-call count exceeds the limit.")
        }
        messageBytes = try Self.addMessageBytes(
          call.id.utf8.count + call.name.utf8.count, to: messageBytes)
        messageBytes = try Self.addMessageBytes(
          Self.validatedJSONByteCount(call.arguments), to: messageBytes)
        if !call.metadata.isEmpty {
          messageBytes = try Self.addMessageBytes(
            Self.validatedJSONByteCount(.object(call.metadata)), to: messageBytes)
        }
      }
      if !message.metadata.isEmpty {
        messageBytes = try Self.addMessageBytes(
          Self.validatedJSONByteCount(.object(message.metadata)), to: messageBytes)
      }
      guard messageBytes <= limits.maxMessageBytes else {
        throw ModelGenerationFailure(
          .limitExceeded,
          "A model message exceeds the byte limit."
        )
      }
      let (sum, overflow) = inputBytes.addingReportingOverflow(messageBytes)
      guard !overflow, sum <= limits.maxInputBytes else {
        throw ModelGenerationFailure(.limitExceeded, "Model input exceeds the byte limit.")
      }
      inputBytes = sum
    }
    guard binaryParts <= limits.maxBinaryParts,
      binaryBytes <= limits.maxBinaryInputBytes
    else {
      throw ModelGenerationFailure(.limitExceeded, "Model media exceeds the declared limits.")
    }
    guard tools.count <= ModelToolContract.maximumDefinitionCount else {
      throw ModelGenerationFailure(.limitExceeded, "Model tool count exceeds the limit.")
    }
    var toolNames: Set<String> = []
    for tool in tools {
      guard Self.validToolName(tool.name), toolNames.insert(tool.name).inserted,
        tool.description.utf8.count <= ModelToolContract.maximumDescriptionUTF8Bytes,
        tool.inputSchema.objectValue != nil
      else {
        throw ModelGenerationFailure(.invalidRequest, "Model tool definition is invalid.")
      }
      inputBytes = try Self.addInputBytes(tool.name.utf8.count, to: inputBytes, limits: limits)
      inputBytes = try Self.addInputBytes(
        tool.description.utf8.count, to: inputBytes, limits: limits)
      inputBytes = try Self.addJSONInputBytes(
        tool.inputSchema, to: inputBytes, limits: limits)
    }
    if !metadata.isEmpty {
      inputBytes = try Self.addJSONInputBytes(
        .object(metadata), to: inputBytes, limits: limits)
    }
    try outputFormat.validate()
    return try ModelInputFootprint(
      messageCount: messages.count,
      inlineInputBytes: inputBytes,
      binaryPartCount: binaryParts,
      binaryInputBytes: binaryBytes
    )
  }

  private static func addJSONInputBytes(
    _ value: JSONValue,
    to current: Int,
    limits: ModelGenerationLimits
  ) throws -> Int {
    try addInputBytes(validatedJSONByteCount(value), to: current, limits: limits)
  }

  private static func validatedJSONByteCount(_ value: JSONValue) throws -> Int {
    do {
      try value.validateStructure(limits: ModelGenerationLimits.jsonStructureLimits)
      return try value.canonicalUTF8ByteCount()
    } catch let failure as ModelGenerationFailure {
      throw failure
    } catch {
      throw ModelGenerationFailure(.invalidRequest, "Model JSON input is invalid.")
    }
  }

  private static func addMessageBytes(_ addition: Int, to current: Int) throws -> Int {
    let (sum, overflow) = current.addingReportingOverflow(addition)
    guard !overflow else {
      throw ModelGenerationFailure(.limitExceeded, "Model message exceeds the byte limit.")
    }
    return sum
  }

  private static func addInputBytes(
    _ addition: Int,
    to current: Int,
    limits: ModelGenerationLimits
  ) throws -> Int {
    let (sum, overflow) = current.addingReportingOverflow(addition)
    guard !overflow, sum <= limits.maxInputBytes else {
      throw ModelGenerationFailure(.limitExceeded, "Model input exceeds the byte limit.")
    }
    return sum
  }

  static func validID(_ value: String) -> Bool {
    (1...ModelIdentityContract.maximumInternalIdentifierUTF8Bytes).contains(value.utf8.count)
      && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57)
          || ($0.value >= 65 && $0.value <= 90)
          || ($0.value >= 97 && $0.value <= 122)
          || $0.value == 46 || $0.value == 45 || $0.value == 95
      }
  }

  static func validToolName(_ value: String) -> Bool {
    ModelToolContract.isValidName(value)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID, modelID, messages, tools, metadata, requiredCapabilities
    case outputFormat, maxOutputBytes, deadline, limits
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    messages = try container.decode([AgentMessage].self, forKey: .messages)
    tools = try container.decode([ModelTool].self, forKey: .tools)
    metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
    requiredCapabilities = try container.decode(
      ModelCapabilities.self, forKey: .requiredCapabilities)
    outputFormat = try container.decode(ModelOutputFormat.self, forKey: .outputFormat)
    limits = try container.decode(ModelGenerationLimits.self, forKey: .limits)
    maxOutputBytes = try container.decode(Int.self, forKey: .maxOutputBytes)
    deadline = try container.decode(DurableDuration.self, forKey: .deadline).value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encodeIfPresent(modelID, forKey: .modelID)
    try container.encode(messages, forKey: .messages)
    try container.encode(tools, forKey: .tools)
    try container.encode(metadata, forKey: .metadata)
    try container.encode(requiredCapabilities, forKey: .requiredCapabilities)
    try container.encode(outputFormat, forKey: .outputFormat)
    try container.encode(maxOutputBytes, forKey: .maxOutputBytes)
    try container.encode(DurableDuration(deadline), forKey: .deadline)
    try container.encode(limits, forKey: .limits)
  }
}

extension ModelBinaryContent {
  func validateGenerationContract() throws {
    guard !data.isEmpty,
      (ModelBinaryContentContract.minimumMIMETypeUTF8Bytes...ModelBinaryContentContract.maximumMIMETypeUTF8Bytes).contains(mimeType.utf8.count),
      mimeType.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }),
      mimeType.filter({ $0 == "/" }).count == 1
    else {
      throw ModelGenerationFailure(
        .invalidRequest, "Model media has an invalid MIME type or payload.")
    }
    if let filename {
      guard (1...ModelBinaryContentContract.maximumFilenameUTF8Bytes).contains(filename.utf8.count),
        !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0")
      else {
        throw ModelGenerationFailure(.invalidRequest, "Model media filename is invalid.")
      }
    }
  }
}

enum ModelContractIdentifier {
  static func isValidExternal(_ value: String) -> Bool {
    guard (1...ModelIdentityContract.maximumExternalIdentifierUTF8Bytes).contains(value.utf8.count)
    else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      !CharacterSet.controlCharacters.contains(scalar)
        && !scalar.properties.isWhitespace
    }
  }
}

extension ModelDescriptor {
  public func validateGenerationContract() throws {
    guard ModelContractIdentifier.isValidExternal(id),
      ModelContractIdentifier.isValidExternal(providerID),
      capabilities.isSubset(of: .allKnown),
      contextWindowTokens.map({ $0 > 0 }) ?? true
    else {
      throw ModelGenerationFailure(.invalidRequest, "Model descriptor is invalid.")
    }

    if let displayName {
      guard (1...ModelIdentityContract.maximumDisplayNameUTF8Bytes).contains(displayName.utf8.count),
        displayName.unicodeScalars.allSatisfy({
          !CharacterSet.controlCharacters.contains($0)
        })
      else {
        throw ModelGenerationFailure(.invalidRequest, "Model descriptor display name is invalid.")
      }
    }
  }
}

public enum ModelRequestEvent: Sendable {
  case contentsChanged(messages: [AgentMessage], metadata: [String: JSONValue])
}

/// Provider output for one model invocation.
///
/// Providers return model content only. Durable message identity, timestamps,
/// transcript ordering, and persistence revisions are owned by Agent runtime.
public struct ModelTurn: Codable, Sendable, Equatable {
  public let content: String
  public let contentParts: [ModelContentPart]
  public let toolCalls: [ToolCall]
  public let metadata: [String: JSONValue]
  public let usage: ModelUsage?
  public let responseID: String?
  public let reasoningSummary: String?
  public let stopReason: ModelStopReason?

  public init(
    content: String,
    toolCalls: [ToolCall] = [],
    metadata: [String: JSONValue] = [:],
    usage: ModelUsage? = nil,
    responseID: String? = nil,
    reasoningSummary: String? = nil,
    stopReason: ModelStopReason? = nil
  ) {
    self.content = content
    self.contentParts = [.text(content)]
    self.toolCalls = toolCalls
    self.metadata = metadata
    self.usage = usage
    self.responseID = responseID
    self.reasoningSummary = reasoningSummary
    self.stopReason = stopReason
  }

  public init(
    contentParts: [ModelContentPart],
    toolCalls: [ToolCall] = [],
    metadata: [String: JSONValue] = [:],
    usage: ModelUsage? = nil,
    responseID: String? = nil,
    reasoningSummary: String? = nil,
    stopReason: ModelStopReason? = nil
  ) {
    self.content = contentParts.compactMap(\.text).joined()
    self.contentParts = contentParts
    self.toolCalls = toolCalls
    self.metadata = metadata
    self.usage = usage
    self.responseID = responseID
    self.reasoningSummary = reasoningSummary
    self.stopReason = stopReason
  }

  private enum CodingKeys: String, CodingKey {
    case content, contentParts, toolCalls, metadata, usage, responseID, reasoningSummary, stopReason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    content = try container.decode(String.self, forKey: .content)
    contentParts = try container.decode([ModelContentPart].self, forKey: .contentParts)
    guard contentParts.compactMap(\.text).joined() == content else {
      throw DecodingError.dataCorruptedError(
        forKey: .contentParts,
        in: container,
        debugDescription: "ModelTurn content must equal the text projection of contentParts."
      )
    }
    toolCalls = try container.decode([ToolCall].self, forKey: .toolCalls)
    metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
    usage = try container.decodeIfPresent(ModelUsage.self, forKey: .usage)
    responseID = try container.decodeIfPresent(String.self, forKey: .responseID)
    reasoningSummary = try container.decodeIfPresent(String.self, forKey: .reasoningSummary)
    stopReason = try container.decodeIfPresent(ModelStopReason.self, forKey: .stopReason)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(content, forKey: .content)
    try container.encode(contentParts, forKey: .contentParts)
    try container.encode(toolCalls, forKey: .toolCalls)
    try container.encode(metadata, forKey: .metadata)
    try container.encodeIfPresent(usage, forKey: .usage)
    try container.encodeIfPresent(responseID, forKey: .responseID)
    try container.encodeIfPresent(reasoningSummary, forKey: .reasoningSummary)
    try container.encodeIfPresent(stopReason, forKey: .stopReason)
  }
}
