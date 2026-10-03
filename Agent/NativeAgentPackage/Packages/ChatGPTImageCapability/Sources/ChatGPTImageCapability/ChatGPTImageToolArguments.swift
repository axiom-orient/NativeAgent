import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

struct ChatGPTGenerateImageToolArguments: Sendable {
  let prompt: String
  let background: ChatGPTImageBackground
  let quality: ChatGPTImageQuality
  let size: String
  let outputFilename: String?

  init(
    _ arguments: JSONValue,
    defaultBackground: ChatGPTImageBackground = .auto,
    defaultQuality: ChatGPTImageQuality = .auto,
    defaultSize: String = "auto",
    additionalKeys: Set<String> = []
  ) throws {
    let object = try ChatGPTImageInputPolicy.object(
      arguments, allowing: ChatGPTImageInputPolicy.commonKeys.union(additionalKeys))
    let rawPrompt = try ChatGPTImageInputPolicy.string("prompt", in: object, required: true) ?? ""
    prompt = try ChatGPTImageInputPolicy.prompt(rawPrompt)
    if let text = try ChatGPTImageInputPolicy.string("background", in: object) {
      guard let value = ChatGPTImageBackground(rawValue: text) else {
        throw AgentError.invalidToolCall("Unsupported image background: \(text)")
      }
      background = value
    } else { background = defaultBackground }
    if let text = try ChatGPTImageInputPolicy.string("quality", in: object) {
      guard let value = ChatGPTImageQuality(rawValue: text) else {
        throw AgentError.invalidToolCall("Unsupported image quality: \(text)")
      }
      quality = value
    } else { quality = defaultQuality }
    size = try ChatGPTImageInputPolicy.size(
      ChatGPTImageInputPolicy.string("size", in: object) ?? defaultSize)
    outputFilename = try ChatGPTImageInputPolicy.string("output_filename", in: object).map {
      let name = try ChatGPTImageInputPolicy.filename($0, maximumCharacters: 128)
      let pngName = name.lowercased().hasSuffix(".png") ? name : name + ".png"
      return try ChatGPTImageInputPolicy.filename(pngName, maximumCharacters: 255)
    }
  }
}

struct ChatGPTEditImageToolArguments: Sendable {
  let images: [ModelBinaryContent]
  let prompt: String
  let background: ChatGPTImageBackground
  let quality: ChatGPTImageQuality
  let size: String
  let outputFilename: String?

  init(_ arguments: JSONValue, context: ToolExecutionContext) throws {
    let common = try ChatGPTGenerateImageToolArguments(arguments, additionalKeys: ["images"])
    guard let payloads = arguments["images"]?.arrayValue,
      (1...ChatGPTImageClient.maximumEditImages).contains(payloads.count) else {
      throw AgentError.invalidToolCall("images.edit requires 1...\(ChatGPTImageClient.maximumEditImages) input images")
    }
    images = try payloads.map { try Self.decodeImage($0, context: context) }
    prompt = common.prompt
    background = common.background
    quality = common.quality
    size = common.size
    outputFilename = common.outputFilename
  }

  static func decodeImage(_ payload: JSONValue, context: ToolExecutionContext) throws -> ModelBinaryContent {
    let object = try ChatGPTImageInputPolicy.object(payload, allowing: [
      "mime_type", "base64", "artifact_relative_path", "sha256", "filename",
    ])
    guard let mimeType = try ChatGPTImageInputPolicy.string("mime_type", in: object, required: true),
      mimeType.lowercased() == "image/png" else {
      throw AgentError.invalidToolCall("Each images.edit input must be image/png")
    }
    let base64 = try ChatGPTImageInputPolicy.string("base64", in: object)
    let relativePath = try ChatGPTImageInputPolicy.string("artifact_relative_path", in: object)
    let digest = try ChatGPTImageInputPolicy.string("sha256", in: object)
    guard (base64 == nil) != (relativePath == nil) else {
      throw AgentError.invalidToolCall("Each image needs exactly one of base64 or artifact_relative_path")
    }
    let data: Data
    if let base64 {
      guard digest == nil else {
        throw AgentError.invalidToolCall("sha256 is only accepted with an artifact_relative_path")
      }
      let maximumEncodedBytes = ((ChatGPTImageClient.maximumInputImageBytes + 2) / 3) * 4
      guard base64.utf8.count <= maximumEncodedBytes,
        let decoded = Data(base64Encoded: base64), !decoded.isEmpty,
        decoded.count <= ChatGPTImageClient.maximumInputImageBytes else {
        throw AgentError.invalidToolCall("Inline image input must contain valid bounded base64")
      }
      data = decoded
    } else if let relativePath, let digest {
      data = try ChatGPTSessionArtifactInputResolver.read(
        relativePath: relativePath, expectedSHA256: digest, context: context)
    } else {
      throw AgentError.invalidToolCall("Artifact-backed image inputs require sha256")
    }
    _ = try ChatGPTImageRasterCodec.decode(data, maximumBytes: ChatGPTImageClient.maximumInputImageBytes)
    let filename = try ChatGPTImageInputPolicy.string("filename", in: object).map {
      try ChatGPTImageInputPolicy.filename($0, maximumCharacters: 255)
    }
    return ModelBinaryContent(mimeType: "image/png", data: data, filename: filename)
  }
}
