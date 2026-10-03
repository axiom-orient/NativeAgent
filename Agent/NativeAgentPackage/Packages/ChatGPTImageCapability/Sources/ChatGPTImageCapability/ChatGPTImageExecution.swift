import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

extension ChatGPTImagesToolPack {
  static func generateResult(
    client: any ChatGPTImageServing,
    arguments: ChatGPTGenerateImageToolArguments,
    callID: String,
    toolName: String,
    promptPrefix: String? = nil
  ) async throws -> ToolResult {
    let combinedPrompt = [promptPrefix, arguments.prompt]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
      .joined(separator: "\n\n")
    let prompt: String
    do { prompt = try ChatGPTImageInputPolicy.prompt(combinedPrompt) }
    catch { throw EffectFailure.definiteFailure(operation: "\(toolName).preflight", cause: error.localizedDescription) }
    // Cancellation before dispatch proves no request was started by this executor.
    if Task.isCancelled {
      throw EffectFailure.definiteFailure(operation: "\(toolName).preflight", cause: "Cancelled before image dispatch")
    }
    let result: ChatGPTImageResult
    do {
      result = try await client.generate(
        ChatGPTImageGenerationRequest(
          prompt: prompt,
          background: arguments.background,
          quality: arguments.quality,
          size: arguments.size
        )
      )
    } catch {
      throw classifiedProviderFailure(error, operation: "images.generate")
    }
    return try makeObservedResult(
      callID: callID,
      toolName: toolName,
      requestPrompt: prompt,
      requestedBackground: arguments.background,
      requestedSize: arguments.size,
      result: result,
      preferredFilename: arguments.outputFilename
    )
  }

  static func editResult(
    client: any ChatGPTImageServing,
    arguments: ChatGPTEditImageToolArguments,
    callID: String,
    toolName: String,
    promptPrefix: String? = nil
  ) async throws -> ToolResult {
    let combinedPrompt = [promptPrefix, arguments.prompt]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
      .joined(separator: "\n\n")
    let prompt: String
    do { prompt = try ChatGPTImageInputPolicy.prompt(combinedPrompt) }
    catch { throw EffectFailure.definiteFailure(operation: "\(toolName).preflight", cause: error.localizedDescription) }
    // Cancellation before dispatch proves no request was started by this executor.
    if Task.isCancelled {
      throw EffectFailure.definiteFailure(operation: "\(toolName).preflight", cause: "Cancelled before image dispatch")
    }
    let result: ChatGPTImageResult
    do {
      result = try await client.edit(
        ChatGPTImageEditRequest(
          images: arguments.images.map(ChatGPTImageContent.init),
          prompt: prompt,
          background: arguments.background,
          quality: arguments.quality,
          size: arguments.size
        )
      )
    } catch {
      throw classifiedProviderFailure(error, operation: "images.edit")
    }
    return try makeObservedResult(
      callID: callID,
      toolName: toolName,
      requestPrompt: prompt,
      requestedBackground: arguments.background,
      requestedSize: arguments.size,
      result: result,
      preferredFilename: arguments.outputFilename
    )
  }

  static func generateArguments(
    _ parameters: JSONValue,
    defaultBackground: ChatGPTImageBackground = .auto,
    defaultQuality: ChatGPTImageQuality = .auto,
    defaultSize: String = "auto",
    operation: String
  ) throws -> ChatGPTGenerateImageToolArguments {
    do {
      return try ChatGPTGenerateImageToolArguments(
        parameters,
        defaultBackground: defaultBackground,
        defaultQuality: defaultQuality,
        defaultSize: defaultSize
      )
    } catch {
      throw EffectFailure.definiteFailure(
        operation: operation,
        cause: error.localizedDescription
      )
    }
  }

  static func editArguments(
    _ parameters: JSONValue,
    context: ToolExecutionContext,
    operation: String
  ) throws -> ChatGPTEditImageToolArguments {
    do {
      return try ChatGPTEditImageToolArguments(parameters, context: context)
    } catch {
      throw EffectFailure.definiteFailure(
        operation: operation,
        cause: error.localizedDescription
      )
    }
  }

  static func classifiedProviderFailure(
    _ error: any Error,
    operation: String
  ) -> EffectFailure {
    guard let failure = error as? ChatGPTImageFailure else {
      return .outcomeUnknown(operation: operation, cause: error.localizedDescription)
    }
    let cause = [failure.localizedDescription, failure.diagnosticDescription]
      .compactMap { $0 }.joined(separator: " · ")
    if let status = failure.httpStatusCode, [400, 401, 403, 413, 422, 429].contains(status) {
      return .definiteFailure(operation: operation, cause: cause)
    }
    switch failure.code {
    case .invalidRequest, .authenticationRequired, .rateLimited:
      return .definiteFailure(operation: operation, cause: cause)
    case .serviceRejected, .malformedResponse, .limitExceeded, .cancelled, .transportFailure:
      return .outcomeUnknown(operation: operation, cause: cause)
    }
  }

  /// Publication failure after a provider result cannot establish absence of an external effect.
  private static func makeObservedResult(
    callID: String,
    toolName: String,
    requestPrompt: String,
    requestedBackground: ChatGPTImageBackground,
    requestedSize: String,
    result: ChatGPTImageResult,
    preferredFilename: String?
  ) throws -> ToolResult {
    do {
      return try ChatGPTImageToolResultBuilder.makeResult(
        callID: callID, toolName: toolName, requestPrompt: requestPrompt,
        requestedBackground: requestedBackground, requestedSize: requestedSize,
        result: result, preferredFilename: preferredFilename)
    } catch {
      throw EffectFailure.outcomeUnknown(
        operation: "\(toolName).publication", cause: error.localizedDescription,
        context: ["providerReturned": "true"])
    }
  }
}
