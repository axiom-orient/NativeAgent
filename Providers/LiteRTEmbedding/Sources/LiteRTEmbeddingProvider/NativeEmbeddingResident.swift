#if canImport(CLiteRTLM) || canImport(CLiteRTLM_mac)
import CryptoKit
import Dispatch
import EmbeddingCore
import Foundation
#if canImport(CLiteRTLM)
import CLiteRTLM
#else
import CLiteRTLM_mac
#endif

/// C I/O storage only. All pointer access occurs on this private serial queue;
/// LiteRTEmbeddingModel alone decides admission, cancellation and shutdown.
/// Queue closures retain this object until every native call has returned.
final class NativeEmbeddingResident: @unchecked Sendable {
  private let queue = DispatchQueue(label: "NativeAgent.LiteRTEmbedding.native", qos: .userInitiated)
  private var handle: OpaquePointer?

  deinit {
    // No queued work can remain: every submitted closure retains self.
    if let handle { litert_lm_embedding_engine_delete(handle) }
  }

  func load(modelURL: URL, cacheDirectory: URL) async throws {
    try await perform {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory),
        isDirectory.boolValue else { throw EmbeddingFailure.invalidInput }
      let file = try FileHandle(forReadingFrom: modelURL)
      let digest: String
      do {
        guard try file.seekToEnd() == EmbeddingGemma2.artifactByteCount else {
          throw EmbeddingFailure.artifactMismatch
        }
        try file.seek(toOffset: 0)
        var sha = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
          sha.update(data: chunk)
        }
        digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
      } catch {
        let readFailure = error
        try file.close()
        throw readFailure
      }
      try file.close()
      guard digest == EmbeddingGemma2.artifactSHA256 else { throw EmbeddingFailure.artifactMismatch }
      guard let metadata = litert_lm_loaded_file_create(modelURL.path) else { throw Self.failure() }
      defer { litert_lm_loaded_file_delete(metadata) }
      // Family modality flags include vision/audio even in this text-only
      // file. The locked digest identifies its actual text/embedder sections.
      guard litert_lm_loaded_file_model_type(metadata) == kLiteRtLmModelTypeEmbedding,
        litert_lm_loaded_file_embedding_dimension(metadata) == 768,
        litert_lm_loaded_file_supports_input_modality(metadata, kLiteRtLmModalityText)
      else { throw EmbeddingFailure.artifactMismatch }
      guard let settings = litert_lm_embedding_engine_settings_create(modelURL.path, "cpu", nil, nil)
      else { throw Self.failure() }
      defer { litert_lm_embedding_engine_settings_delete(settings) }
      litert_lm_embedding_engine_settings_set_cache_dir(settings, cacheDirectory.path)
      litert_lm_embedding_engine_settings_set_num_threads(settings, 2)
      litert_lm_embedding_engine_settings_set_max_input_length(settings, Int32(EmbeddingGemma2.maximumInputTokens))
      litert_lm_embedding_engine_settings_set_activation_data_type(settings, kLiteRtLmActivationDataTypeFloat32)
      guard let engine = litert_lm_embedding_engine_create(settings) else { throw Self.failure() }
      self.handle = engine
    }
  }

  func compute(_ text: String) async throws -> [Float] {
    try await perform {
      guard let engine = self.handle else { throw EmbeddingFailure.closed }
      let input = text.withCString {
        litert_lm_input_data_create(kLiteRtLmInputDataTypeText, $0, text.utf8.count)
      }
      guard let input else { throw Self.failure() }
      defer { litert_lm_input_data_delete(input) }
      guard let options = litert_lm_embedding_options_create() else { throw Self.failure() }
      defer { litert_lm_embedding_options_delete(options) }
      litert_lm_embedding_options_set_normalize(options, false)
      litert_lm_embedding_options_set_insert_special_tokens(options, true)
      litert_lm_embedding_options_set_input_overflow_strategy(options, kLiteRtLmInputOverflowStrategyError)
      litert_lm_embedding_options_set_output_size(options, 768)
      let inputs: [OpaquePointer?] = [input]
      let response = inputs.withUnsafeBufferPointer {
        litert_lm_embedding_engine_compute_embedding(engine, $0.baseAddress, $0.count, options)
      }
      guard let response else { throw Self.failure() }
      defer { litert_lm_embedding_response_delete(response) }
      guard litert_lm_embedding_response_get_size(response) == 768 else {
        throw EmbeddingFailure.invalidDimension
      }
      guard let values = litert_lm_embedding_response_get_values(response) else {
        throw EmbeddingFailure.invalidVector
      }
      return Array(UnsafeBufferPointer(start: values, count: 768))
    }
  }

  func close() async {
    await withCheckedContinuation { continuation in
      queue.async {
        if let handle = self.handle {
          self.handle = nil
          litert_lm_embedding_engine_delete(handle)
        }
        continuation.resume()
      }
    }
  }

  private func perform<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try operation()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  private static func failure() -> EmbeddingFailure {
    // Thread-local native diagnostics may contain input text or file paths.
    // Expose the actual status code without exporting those private values.
    .nativeFailure(code: Int(litert_lm_get_last_error_code()))
  }
}
#endif
