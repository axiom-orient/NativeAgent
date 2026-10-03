import AppleLocalAICore
import Foundation
import FoundationModels

public struct AppleLocalAIRequest: Sendable {
  /// The original Foundation Models prompt. No parallel prompt representation
  /// is introduced by the package.
  public let prompt: Prompt

  /// Validated text convenience.
  public init(text: String) throws {
    do {
      let normalized = try NormalizedPrompt(text)
      self.prompt = Prompt(normalized.value)
    } catch {
      throw AppleLocalAIError.emptyPrompt
    }
  }

  /// Native multimodal convenience for a file-backed image. The caller owns any
  /// security-scoped file access needed by the URL.
  public init(text: String, imageURL: URL, imageLabel: String? = nil) throws {
    let normalized: NormalizedPrompt
    do { normalized = try NormalizedPrompt(text) }
    catch { throw AppleLocalAIError.emptyPrompt }

    self.prompt = Prompt {
      normalized.value
      if let imageLabel, !imageLabel.isEmpty {
        Attachment(imageURL: imageURL).label(imageLabel)
      } else {
        Attachment(imageURL: imageURL)
      }
    }
  }

  /// Escape hatch for native Foundation Models prompts, including multiple
  /// attachments or custom PromptRepresentable values.
  public init(prompt: Prompt) {
    self.prompt = prompt
  }
}
