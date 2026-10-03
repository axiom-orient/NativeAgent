import Foundation
import CoreFoundation
import LanguageModelCore
@_spi(Service) import ChatGPTAccount
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private enum ChatGPTWireLimits {
  static let maximumResponseHeaderCount = 256
  static let maximumJSONObjectBytes = 256 * 1_024
}

enum ChatGPTWireError: Error, Sendable, Equatable {
  case limitExceeded
  case invalidResponse
  case duplicateResponse
  case bodyBeforeResponse
  case responseTooLarge
  case malformedSSE
  case tooManyEvents
  case httpStatus(Int)
  case serviceFailure
  case policyViolation
  case unsupportedEvent
  case terminalMissing
  case duplicateTerminal
}

/// The SSE parser owns its producer; it never treats buffered HTTP EOF as drain.
struct ChatGPTSSEInvocation: Sendable {
  let events: AsyncThrowingStream<ChatGPTSSEEvent, any Error>
  let cancel: @Sendable () -> Void
  let waitForCompletion: @Sendable () async throws -> Void
}

func chatGPTSSE(
  transport: any ChatGPTTransport,
  request: URLRequest,
  maxResponseBytes: Int,
  maxFrameBytes: Int
) -> ChatGPTSSEInvocation {
  let (events, continuation) = AsyncThrowingStream<ChatGPTSSEEvent, any Error>.makeStream(
    bufferingPolicy: .bufferingOldest(ChatGPTSSEParser.standardMaximumEvents))
  let producer = Task {
    do {
      try Task.checkCancellation()
      let initialParser = try ChatGPTSSEParser(maxEventBytes: maxFrameBytes)
      let operation = try await transport.invocation(request, maxResponseBytes: maxResponseBytes)
      try await operation.consuming { stream in
          var parser = initialParser
          var receivedHead = false
          var totalBytes = 0
          for try await element in stream {
            try Task.checkCancellation()
            switch element {
            case .response(let statusCode, let headers):
              guard !receivedHead, (100...599).contains(statusCode),
                headers.count <= ChatGPTWireLimits.maximumResponseHeaderCount
              else { throw ChatGPTWireError.duplicateResponse }
              receivedHead = true
              guard (200...299).contains(statusCode) else {
                throw ChatGPTWireError.httpStatus(statusCode)
              }
            case .body(let data):
              guard receivedHead else { throw ChatGPTWireError.bodyBeforeResponse }
              let (next, overflow) = totalBytes.addingReportingOverflow(data.count)
              guard !overflow, next <= maxResponseBytes else {
                throw ChatGPTWireError.responseTooLarge
              }
              totalBytes = next
              for event in try parser.feed(data) { try publish(event) }
            }
          }
          try Task.checkCancellation()
          guard receivedHead else { throw ChatGPTWireError.invalidResponse }
          for event in try parser.feed(Data(), finish: true) { try publish(event) }
      }
      continuation.finish()
    } catch let error as ChatGPTTransportDrainFailure {
      let failure = ModelExecutorDrainFailure(
        "ChatGPT HTTP transport did not prove local completion.", retaining: error)
      continuation.finish(throwing: failure)
      throw failure
    } catch {
      // HTTP/parser/cancellation failures are event outcomes, not failed local drain.
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { termination in
    if case .cancelled = termination { producer.cancel() }
  }
  return ChatGPTSSEInvocation(
    events: events, cancel: { producer.cancel() },
    waitForCompletion: { try await producer.value })

  @Sendable func publish(_ event: ChatGPTSSEEvent) throws {
    switch continuation.yield(event) {
    case .enqueued: break
    case .terminated: throw CancellationError()
    case .dropped: throw ChatGPTWireError.tooManyEvents
    @unknown default: throw ChatGPTWireError.invalidResponse
    }
  }


}

func chatGPTJSON(_ object: Any) throws -> Data {
  guard JSONSerialization.isValidJSONObject(object) else { throw ChatGPTWireError.malformedSSE }
  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func chatGPTJSONObject(_ data: Data) throws -> [String: Any] {
  guard data.count <= ChatGPTWireLimits.maximumJSONObjectBytes else { throw ChatGPTWireError.malformedSSE }
  do {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ChatGPTWireError.malformedSSE
    }
    return object
  } catch let error as ChatGPTWireError {
    throw error
  } catch {
    throw ChatGPTWireError.malformedSSE
  }
}

func chatGPTString(_ object: [String: Any], _ key: String) -> String? { object[key] as? String }
func chatGPTObject(_ object: [String: Any], _ key: String) -> [String: Any]? {
  object[key] as? [String: Any]
}

func chatGPTInteger(_ object: [String: Any], _ key: String) -> Int64? {
  guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else {
    return nil
  }
  let value = number.int64Value
  guard number.doubleValue == Double(value), value >= 0 else { return nil }
  return value
}

func chatGPTFailure(_ error: any Error) -> ModelGenerationFailure {
  if let transportError = error as? ChatGPTTransportError {
    switch transportError {
    case .limitExceeded, .responseTooLarge:
      return ModelGenerationFailure(.limitExceeded, "The provider response exceeded its declared limits.")
    case .invalidResponse, .duplicateResponse, .bodyBeforeResponse:
      return ModelGenerationFailure(.malformedEvent, "The provider stream was malformed.")
    }
  }
  if let failure = error as? ModelGenerationFailure {
    return chatGPTCanonicalFailure(failure.code)
  }
  if error is CancellationError || Task.isCancelled {
    return ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
  }
  switch error as? ChatGPTWireError {
  case .limitExceeded, .responseTooLarge, .tooManyEvents:
    return ModelGenerationFailure(.limitExceeded, "The provider response exceeded its declared limits.")
  case .malformedSSE, .invalidResponse, .duplicateResponse, .bodyBeforeResponse, .unsupportedEvent:
    return ModelGenerationFailure(.malformedEvent, "The provider stream was malformed.")
  case .terminalMissing:
    return ModelGenerationFailure(.terminalMissing, "The provider stream ended without completion.")
  case .duplicateTerminal:
    return ModelGenerationFailure(.duplicateTerminal, "The provider emitted data after completion.")
  case .policyViolation:
    return ModelGenerationFailure(
      .policyViolation, "The provider emitted a forbidden tool or effect event.")
  case .httpStatus(let status):
    return ModelGenerationFailure(.transportFailure, "The provider returned HTTP status \(status).")
  case .serviceFailure:
    return ModelGenerationFailure(.transportFailure, "The provider reported a generation failure.")
  case nil: return ModelGenerationFailure(.transportFailure, "Model transport failed.")
  }
}

private func chatGPTCanonicalFailure(_ code: ModelGenerationErrorCode) -> ModelGenerationFailure {
  switch code {
  case .invalidRequest: return ModelGenerationFailure(.invalidRequest, "The model request is invalid.")
  case .authenticationRequired:
    return ModelGenerationFailure(.authenticationRequired, "Sign in with ChatGPT is required.")
  case .sourceUnavailable: return ModelGenerationFailure(.sourceUnavailable, "ChatGPT is unavailable.")
  case .limitExceeded:
    return ModelGenerationFailure(.limitExceeded, "The provider response exceeded its declared limits.")
  case .cancelled: return ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
  case .deadlineExceeded:
    return ModelGenerationFailure(.deadlineExceeded, "Model generation exceeded its deadline.")
  case .transportFailure: return ModelGenerationFailure(.transportFailure, "Model transport failed.")
  case .malformedEvent: return ModelGenerationFailure(.malformedEvent, "The provider stream was malformed.")
  case .terminalMissing:
    return ModelGenerationFailure(.terminalMissing, "The provider stream ended without completion.")
  case .duplicateTerminal:
    return ModelGenerationFailure(.duplicateTerminal, "The provider emitted data after completion.")
  case .policyViolation:
    return ModelGenerationFailure(
      .policyViolation, "The provider emitted a forbidden tool or effect event.")
  }
}

func chatGPTValidateModel(_ model: String) throws {
  guard !model.isEmpty, model.utf8.count <= ChatGPTProtocolProfile.maximumProtocolIdentityUTF8Bytes,
    model.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
    !model.contains("/"), !model.contains("?"), !model.contains("#")
  else { throw ModelGenerationFailure(.invalidRequest, "Model identifier is invalid.") }
}

func chatGPTOutputFields(_ format: ModelOutputFormat) throws -> [String: Any]? {
  guard case .jsonObject(let value) = format else { return nil }
  let data = try JSONEncoder().encode(value)
  guard let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ChatGPTFailure(.invalidConfiguration)
  }
  return schema
}
