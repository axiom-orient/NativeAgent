import AppleLocalAICore
import Foundation
import FoundationModels

@MainActor
public final class AppleLocalAISession {
  public enum Phase: Equatable, Sendable {
    case idle
    case running
    case cancelling
  }

  private var nativeSession: LanguageModelSession
  private let operations = OperationController()

  public init(
    profile: AppleLocalAIProfile,
    history: [Transcript.Entry] = []
  ) {
    let session = LanguageModelSession(
      profile: AppleLocalAIRootProfile(),
      history: history
    )
    session.properties.appleLocalAIProfile = profile
    self.nativeSession = session
  }

  public var phase: Phase {
    switch operations.lifecycle {
    case .idle: .idle
    case .running: .running
    case .cancelling: .cancelling
    }
  }

  public var transcript: Transcript { nativeSession.transcript }
  public var history: [Transcript.Entry] { Array(nativeSession.transcript.history) }
  public var usage: LanguageModelSession.Usage { nativeSession.usage }
  /// The model currently installed in the native session's dynamic profile.
  public var activeModel: (any LanguageModel)? {
    nativeSession.properties.appleLocalAIProfile?.model
  }
  public var modelCapabilities: AppleLocalAIModelCapabilities? {
    activeModel.map { AppleLocalAIModelCapabilities($0.capabilities) }
  }
  public var isBusy: Bool { operations.isBusy }

  /// Changes the active dynamic profile without creating another transcript owner.
  public func reconfigure(_ profile: AppleLocalAIProfile) throws {
    guard !operations.isBusy else { throw AppleLocalAIError.operationInProgress }
    nativeSession.properties.appleLocalAIProfile = profile
  }

  /// Explicitly starts a new conversation. This is the only API that replaces the
  /// native session and therefore discards the old transcript authority.
  public func reset(
    profile: AppleLocalAIProfile,
    history: [Transcript.Entry] = []
  ) throws {
    guard !operations.isBusy else { throw AppleLocalAIError.operationInProgress }
    let session = LanguageModelSession(
      profile: AppleLocalAIRootProfile(),
      history: history
    )
    session.properties.appleLocalAIProfile = profile
    nativeSession = session
  }

  public func feedbackAttachment(
    sentiment: LanguageModelFeedback.Sentiment? = nil,
    issues: [LanguageModelFeedback.Issue] = [],
    desiredResponseText: String? = nil
  ) throws -> Data {
    guard !operations.isBusy else { throw AppleLocalAIError.operationInProgress }
    return nativeSession.logFeedbackAttachment(
      sentiment: sentiment,
      issues: issues,
      desiredResponseText: desiredResponseText
    )
  }

  public func prewarm(promptPrefix: Prompt? = nil) throws {
    guard !operations.isBusy else { throw AppleLocalAIError.operationInProgress }
    nativeSession.prewarm(promptPrefix: promptPrefix)
  }

  public func cancel() {
    operations.cancel()
  }

  public func respond(
    _ request: AppleLocalAIRequest,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) async throws -> LanguageModelSession.Response<String> {
    try await perform {
      try await self.nativeSession.respond(
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
    }
  }

  public func stream(
    _ request: AppleLocalAIRequest,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: [String: any ConvertibleToGeneratedContent] = [:],
    onSnapshot: @escaping @MainActor (AppleLocalAITextSnapshot) -> Void
  ) async throws -> AppleLocalAITextSnapshot {
    try await perform {
      var latest: AppleLocalAITextSnapshot?
      let stream = self.nativeSession.streamResponse(
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
      for try await snapshot in stream {
        try Task.checkCancellation()
        let value = AppleLocalAITextSnapshot(
          text: snapshot.content,
          rawContent: snapshot.rawContent,
          usage: snapshot.usage,
          transcriptEntries: Array(snapshot.transcriptEntries)
        )
        latest = value
        onSnapshot(value)
      }
      guard let latest else { throw AppleLocalAIStreamError.emptyStream }
      return latest
    }
  }

  /// Streams native structured output while preserving Foundation Models'
  /// partial-generation type and raw generated content.
  public func streamGenerated<Content: Generable & Sendable>(
    _ request: AppleLocalAIRequest,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:],
    onSnapshot: @escaping @MainActor (AppleLocalAIGeneratedSnapshot<Content>) -> Void
  ) async throws -> AppleLocalAIGeneratedSnapshot<Content>
  where Content.PartiallyGenerated: Sendable {
    try await perform {
      var latest: AppleLocalAIGeneratedSnapshot<Content>?
      let stream = self.nativeSession.streamResponse(
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
      for try await snapshot in stream {
        try Task.checkCancellation()
        let value = AppleLocalAIGeneratedSnapshot<Content>(
          content: snapshot.content,
          rawContent: snapshot.rawContent,
          usage: snapshot.usage,
          transcriptEntries: Array(snapshot.transcriptEntries)
        )
        latest = value
        onSnapshot(value)
      }
      guard let latest else { throw AppleLocalAIStreamError.emptyStream }
      return latest
    }
  }

  public func generate<Content: Generable & Sendable>(
    _ request: AppleLocalAIRequest,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) async throws -> LanguageModelSession.Response<Content> {
    try await perform {
      try await self.nativeSession.respond(
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
    }
  }

  public func generate(
    _ request: AppleLocalAIRequest,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) async throws -> LanguageModelSession.Response<GeneratedContent> {
    try await perform {
      try await self.nativeSession.respond(
        schema: schema,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
    }
  }

  /// Counts prompt tokens using Apple's iOS 27 `SystemLanguageModel` API.
  /// Local model conformers and Private Cloud Compute do not expose an
  /// equivalent token-counting API in the iOS 27 SDK, so this method reports a
  /// typed unavailability error for those active models.
  public func tokenCount(for request: AppleLocalAIRequest) async throws -> Int {
    try await tokenCount(for: request.prompt)
  }

  public func tokenCount(for prompt: Prompt) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: prompt)
  }

  public func tokenCount(for instructions: Instructions) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: instructions)
  }

  public func tokenCount(for tools: [any Tool]) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: tools)
  }

  public func tokenCount(for schema: GenerationSchema) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: schema)
  }

  public func tokenCount(for transcriptEntries: [Transcript.Entry]) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: transcriptEntries)
  }

  private func perform<Value: Sendable>(
    _ effect: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operations.perform(effect)
    } catch is CancellationError {
      throw AppleLocalAIError.cancelled
    } catch OperationLifecycle.TransitionError.operationAlreadyActive {
      throw AppleLocalAIError.operationInProgress
    }
  }

  private func systemModelForTokenCounting() throws -> SystemLanguageModel {
    guard !operations.isBusy else { throw AppleLocalAIError.operationInProgress }
    guard let model = activeModel as? SystemLanguageModel else {
      throw AppleLocalAIError.tokenCountUnavailable
    }
    return model
  }


}

public struct AppleLocalAITextSnapshot: Sendable {
  public let text: String
  public let rawContent: GeneratedContent
  public let usage: LanguageModelSession.Usage
  public let transcriptEntries: [Transcript.Entry]

  public var transcriptEntryCount: Int { transcriptEntries.count }
}

public struct AppleLocalAIGeneratedSnapshot<Content: Generable & Sendable>: Sendable
where Content.PartiallyGenerated: Sendable {
  public let content: Content.PartiallyGenerated
  public let rawContent: GeneratedContent
  public let usage: LanguageModelSession.Usage
  public let transcriptEntries: [Transcript.Entry]

  public var transcriptEntryCount: Int { transcriptEntries.count }
}

public enum AppleLocalAIStreamError: Error, Sendable {
  case emptyStream
}
