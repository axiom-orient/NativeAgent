#if canImport(FoundationModels, _version: 2)
  import Foundation
  import FoundationModels
  import LanguageModelCore

  /// An explicitly chosen Apple model projected into the NativeAI contract.
  /// Exact text only: native tool execution, media, reasoning and guided output
  /// are NOT advertised until their transport/approval contracts are implemented.
  /// Session instances are invocation-local translations, never history owners.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
  public struct FoundationLanguageModel<Native: FoundationModels.LanguageModel>: LanguageModelCore
      .LanguageModel
  {
    public var descriptor: ModelDescriptor { executorConfiguration.binding.descriptor }
    public let executorConfiguration: Executor.Configuration

    public init(model: Native, providerID: String, modelID: String, displayName: String? = nil)
      throws
    {
      let descriptor = ModelDescriptor(
        id: modelID, providerID: providerID,
        displayName: displayName, capabilities: .textOnly)
      try descriptor.validateGenerationContract()
      executorConfiguration = Executor.Configuration(
        binding: Binding(native: model, descriptor: descriptor))
    }

    fileprivate final class Binding: Sendable {
      let native: Native
      let descriptor: ModelDescriptor
      init(native: Native, descriptor: ModelDescriptor) {
        self.native = native
        self.descriptor = descriptor
      }
    }

    public struct Executor: LanguageModelCore.LanguageModelExecutor {
      public typealias Model = FoundationLanguageModel<Native>
      public struct Configuration: Hashable, Sendable {
        fileprivate let binding: Binding
        // Native models may contain non-Hashable loader/credential closures outside
        // their SDK executor configuration. Only copies of one admitted binding
        // may alias; a display/model name is never a resource-identity shortcut.
        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.binding === rhs.binding }
        public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(binding)) }
      }
      private let configuration: Configuration
      public init(configuration: Configuration) { self.configuration = configuration }

      public func respond(
        to request: ModelRequest, model: Model,
        streamingInto channel: ModelGenerationChannel
      ) async throws {
        guard configuration == model.executorConfiguration else {
          throw ModelGenerationFailure(
            .invalidRequest, "The native executor binding does not match its model.")
        }
        let text = try ModelTextRequest(request, descriptor: model.descriptor)
        try request.validateSupportedCapabilities(model.capabilities)
        try Task.checkCancellation()
        let session = FoundationModels.LanguageModelSession(
          model: configuration.binding.native, tools: [], transcript: try Self.transcript(text))
        // No producer Task, duplicate controller or speculative prewarm is created.
        // Await the SDK request boundary; host/native executor owns resident memory.
        try channel.send(.started(descriptor: model.descriptor))
        do {
          let response = try await session.respond(to: FoundationModels.Prompt(text.prompt))
          try Task.checkCancellation()
          try text.validateOutput(response.content)
          try channel.send(.completed(ModelTurn(content: response.content)))
        } catch is CancellationError { throw CancellationError() } catch let failure
          as ModelGenerationFailure
        { throw failure } catch { throw FoundationModelFailure(underlyingError: error) }
      }

      private static func transcript(_ text: ModelTextRequest) throws -> FoundationModels.Transcript
      {
        var entries: [FoundationModels.Transcript.Entry] = []
        if !text.instructions.isEmpty {
          entries.append(
            .instructions(
              .init(segments: [.text(.init(content: text.instructions))], toolDefinitions: [])))
        }
        for message in text.history {
          let segment = FoundationModels.Transcript.Segment.text(
            .init(id: "\(message.id)-text", content: message.content))
          switch message.role {
          case .user: entries.append(.prompt(.init(id: message.id, segments: [segment])))
          case .assistant:
            entries.append(.response(.init(id: message.id, assetIDs: [], segments: [segment])))
          case .system, .tool:
            throw ModelGenerationFailure(
              .invalidRequest, "An unsupported role crossed the native text projection.")
          }
        }
        return FoundationModels.Transcript(entries: entries)
      }
    }
  }

  /// The public category stays vendor-neutral; the original error remains available
  /// as evidence without leaking prompts/credentials into automatic log messages.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
  public struct FoundationModelFailure: ModelClientFailure {
    public let underlyingError: any Error
    public let category: ModelGenerationFailure
    public init(underlyingError: any Error) {
      self.underlyingError = underlyingError
      category = Self.map(underlyingError)
    }

    private static func map(_ error: any Error) -> ModelGenerationFailure {
      switch error {
      case let error as FoundationModels.LanguageModelError:
        switch error {
        case .contextSizeExceeded:
          return .init(.limitExceeded, "Native model context limit exceeded.")
        case .guardrailViolation, .refusal:
          return .init(.policyViolation, "Native model rejected the request.")
        case .rateLimited, .unsupportedLanguageOrLocale, .timeout:
          return .init(.sourceUnavailable, "Native model is temporarily unavailable.")
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
          return .init(.invalidRequest, "Native model does not support the requested input.")
        @unknown default:
          return .init(.transportFailure, "Native model generation failed.")
        }
      case is FoundationModels.SystemLanguageModel.Error:
        return .init(.sourceUnavailable, "Native model assets are unavailable.")
      case is FoundationModels.GeneratedContent.ParsingError:
        return .init(.malformedEvent, "Native model response decoding failed.")
      case let error as FoundationModels.LanguageModelSession.Error:
        switch error {
        case .concurrentRequests:
          return .init(.sourceUnavailable, "Native model is temporarily unavailable.")
        case .transcriptMutationWhileResponding:
          return .init(.invalidRequest, "Native model transcript changed during generation.")
        @unknown default:
          return .init(.transportFailure, "Native model generation failed.")
        }
      default:
        return .init(.transportFailure, "Native model generation failed.")
      }
    }

    public var errorDescription: String? { category.message }
    public var modelFailureCode: String { category.code.rawValue }
    public var modelFailureDetails: [String: JSONValue] {
      ["nativeErrorType": .string(String(reflecting: type(of: underlyingError)))]
    }
  }
#endif
