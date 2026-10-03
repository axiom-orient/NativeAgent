import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import LanguageModelCore

// Structured output is explicitly greedy. Regular text keeps model sampling.
enum MLXGuidedOutput {
  static func isEligible(request: ModelRequest, sampling: MLXSampling) -> Bool {
    guard case .jsonObject = request.outputFormat else { return false }
    return request.tools.isEmpty && sampling.temperature == 0 && sampling.repetitionPenalty == 1
  }

  static func generate(
    model: ModelContainer, request: ModelRequest, specification: MLXModelSpecification,
    maxTokens: Int, emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws {
    guard case .jsonObject(let schema) = request.outputFormat,
      request.tools.isEmpty,
      specification.sampling.temperature == 0,
      specification.sampling.repetitionPenalty == 1
    else {
      throw ModelGenerationFailure(.invalidRequest,
        "MLX constrained JSON requires a tool-free request, temperature 0 and repetition penalty 1.")
    }
    let schemaText = try MLXGrammarSchema.encode(schema)
    let turn = try await model.perform { context in
      defer { Stream.gpu.synchronize() }
      try Task.checkCancellation()
      let chat = try MLXChatMapper.map(request: request, disablesThinking: specification.disablesThinking)
      let input = try await context.processor.prepare(input: UserInput(
        chat: chat.history + [chat.current],
        additionalContext: specification.disablesThinking ? ["enable_thinking": false] : [:]))
      let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
      guard let eos = context.tokenizer.eosTokenId, let eos32 = Int32(exactly: eos), !vocabulary.vocab.isEmpty else {
        throw ModelGenerationFailure(.sourceUnavailable, "MLX grammar tokenizer has no valid vocabulary or EOS.")
      }
      let tokenizer = try GrammarTokenizer(vocab: vocabulary.vocab,
        vocabType: vocabulary.vocabType, eosTokenId: eos32)
      let constraint = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schemaText,
        fastForward: false, hostTokenizer: context.tokenizer)
      var output = Data()
      var failure: (any Error)?
      let generated: Int
      do {
        generated = try GuidedGenerationLoop.run(input: input, context: context,
          constraint: constraint, maxTokens: maxTokens, vocabSize: tokenizer.vocabSize) { chunk in
          do {
            try Task.checkCancellation()
            for delta in try request.limits.boundedDeltas(for: chunk) {
              guard delta.utf8.count <= request.maxOutputBytes - output.count else {
                throw ModelGenerationFailure(.limitExceeded, "MLX JSON output exceeds the byte limit.")
              }
              output.append(contentsOf: delta.utf8); emit(.textDelta(delta))
            }
            return true
          } catch { failure = error; return false }
        }
      } catch {
        if let failure { throw failure }
        throw error
      }
      if let failure { throw failure }
      try Task.checkCancellation()
      let content = String(decoding: output, as: UTF8.self)
      try MLXOutputSchema.validateOutput(content, schema: schema)
      let promptCount = input.text.tokens.size
      let usage = ModelUsage(inputTokens: promptCount, outputTokens: generated, totalTokens: promptCount + generated)
      return ModelTurn(content: content, usage: usage, stopReason: .stop)
    }
    try Task.checkCancellation()
    try turn.validateGenerationContract(for: request)
    if let usage = turn.usage { emit(.usage(usage)) }
    emit(.completed(turn))
  }
}
