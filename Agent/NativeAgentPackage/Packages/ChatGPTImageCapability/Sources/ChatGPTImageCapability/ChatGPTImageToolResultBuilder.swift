import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

enum ChatGPTImageToolResultBuilder {
  static func makeResult(
    callID: String,
    toolName: String,
    requestPrompt: String,
    requestedBackground: ChatGPTImageBackground,
    requestedSize: String,
    result: ChatGPTImageResult,
    preferredFilename: String?
  ) throws -> ToolResult {
    guard result.image.mimeType.lowercased() == "image/png" else {
      throw AgentError.invalidToolCall("Image provider returned a non-PNG MIME type")
    }
    let verification = try ChatGPTImageArtifactInspector.inspect(
      result.image.data,
      requestedBackground: requestedBackground,
      requestedSize: requestedSize
    )
    let filename = try sanitizedFilename(
      preferredFilename ?? result.image.filename ?? defaultFilename(for: toolName)
    )
    let promptSHA256 = SHA256HexDigest.digest(requestPrompt)

    let metadata: [String: JSONValue] = [
      "providerID": .string(ChatGPTImagesCapability.providerID),
      "model": .string(ChatGPTImageClient.model),
      "mimeType": .string(result.image.mimeType),
      "providerBackground": result.background.map { .string($0.rawValue) } ?? .null,
      "requestedBackground": .string(requestedBackground.rawValue),
      "quality": result.quality.map { .string($0.rawValue) } ?? .null,
      "providerSize": result.size.map(JSONValue.string) ?? .null,
      "requestedSize": .string(requestedSize),
      "promptSHA256": .string(promptSHA256),
      "imageGenerationRequestID": result.imageGenerationRequestID.map(JSONValue.string) ?? .null,
      "verification": verification.jsonValue,
      "semanticVerification": .string("not_run"),
      "verificationScope": .string("png_structure_dimensions_alpha_only"),
    ]

    let content: String
    switch verification.status {
    case .verified:
      content = "Image artifact created; PNG structure, size and alpha observations accepted: \(filename)"
    case .structuralOnly:
      content = "Image artifact created with structural verification only: \(filename)"
    case .needsRepair:
      content = "Image artifact created, but requested output constraints need repair/review: \(filename)"
    }

    return ToolResult(
      callID: callID,
      toolName: toolName,
      output: .object([
        "content": .string(content),
        "filename": .string(filename),
        "mime_type": .string(result.image.mimeType),
        "verification": verification.jsonValue,
        "semanticVerification": .string("not_run"),
        "verificationScope": .string("png_structure_dimensions_alpha_only"),
      ]),
      isError: verification.status != .verified,
      artifacts: [
        ArtifactWriteRequest(
          preferredFilename: filename,
          mimeType: result.image.mimeType,
          data: result.image.data,
          metadata: metadata
        )
      ],
      metadata: metadata
    )
  }

  private static func defaultFilename(for toolName: String) -> String {
    "\(toolName.replacingOccurrences(of: ".", with: "-")).png"
  }

  private static func sanitizedFilename(_ filename: String) throws -> String {
    let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    let plain = trimmed.isEmpty ? "image.png" : trimmed
    let noPath = plain.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? plain
    let output = noPath.lowercased().hasSuffix(".png") ? noPath : noPath + ".png"
    return try ChatGPTImageInputPolicy.filename(output, maximumCharacters: 255)
  }
}
