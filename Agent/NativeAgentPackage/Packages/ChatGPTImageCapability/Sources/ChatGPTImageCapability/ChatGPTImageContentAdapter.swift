import ChatGPTImage
import LanguageModelCore

extension ChatGPTImageContent {
  init(_ content: ModelBinaryContent) {
    self.init(mimeType: content.mimeType, data: content.data, filename: content.filename)
  }
}
