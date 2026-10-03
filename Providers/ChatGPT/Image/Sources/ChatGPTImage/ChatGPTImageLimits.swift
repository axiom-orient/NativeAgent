import Foundation

/// Fixed wire and safety bounds. Per-request budgets are validated by the client.
enum ChatGPTImageLimits {
  static let model = "gpt-image-2"
  static let maximumEditImages = 5
  static let maximumInputImageBytes = 50 * 1_024 * 1_024
  static let maximumImageBytes = 32 * 1_024 * 1_024
  static let maximumPromptUTF8Bytes = 32 * 1_024
  static let maximumPNGPixelCount = 16 * 1_024 * 1_024
  static let maximumPNGDecodedBytes = 64 * 1_024 * 1_024
  static let defaultMaximumRequestBytes = 96 * 1_024 * 1_024
  static let maximumEditRequestBytes = 336 * 1_024 * 1_024
  static let minimumRequestOrResponseBytes = 64 * 1_024
  static let defaultMaximumResponseBytes = 48 * 1_024 * 1_024
}
