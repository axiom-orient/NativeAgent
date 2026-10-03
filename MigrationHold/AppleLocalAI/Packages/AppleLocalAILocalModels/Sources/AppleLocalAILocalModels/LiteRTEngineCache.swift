// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Parts of this implementation were originally authored by @john-rocky and
// ported from https://github.com/john-rocky/swift-litert-lm/tree/main.

#if canImport(FoundationModels) && compiler(>=6.4)

  import Foundation
  @preconcurrency import LiteRTLM

  /// Process-wide cache of one lazily initialized engine per configuration.
  @available(iOS 27.0, macOS 27.0, *)
  final class EngineCache: @unchecked Sendable {
    static let shared = EngineCache()

    private let lock = NSLock()
    private var engines: [LiteRTLMExecutor.Configuration: LazyEngine] = [:]

    func engine(for configuration: LiteRTLMExecutor.Configuration) -> LazyEngine {
      lock.lock()
      defer { lock.unlock() }
      if let engine = engines[configuration] { return engine }
      let engine = LazyEngine(configuration: configuration)
      engines[configuration] = engine
      return engine
    }

    func purgeAll() async {
      for engine in drain() { await engine.release() }
    }

    private func drain() -> [LazyEngine] {
      lock.lock()
      defer { lock.unlock() }
      let all = Array(engines.values)
      engines.removeAll()
      return all
    }
  }

  /// Defers native engine initialization until an async operation needs it.
  @available(iOS 27.0, macOS 27.0, *)
  actor LazyEngine {
    private let configuration: LiteRTLMExecutor.Configuration
    private var engineTask: Task<Engine, Error>?
    private var warmupTask: Task<Void, Error>?

    init(configuration: LiteRTLMExecutor.Configuration) {
      self.configuration = configuration
    }

    func ready() async throws -> Engine {
      try Task.checkCancellation()
      let task: Task<Engine, Error>
      if let existing = engineTask {
        task = existing
      } else {
        let configuration = self.configuration
        task = Task {
          try Task.checkCancellation()
          let created = Engine(engineConfig: configuration.engineConfig)
          try await created.initialize()
          try Task.checkCancellation()
          return created
        }
        engineTask = task
      }

      let engine: Engine
      do {
        engine = try await task.value
      } catch {
        if engineTask == task { engineTask = nil }
        throw error
      }
      try Task.checkCancellation()
      guard engineTask == task else { throw CancellationError() }
      return engine
    }

    func prewarmed() async throws {
      let engine = try await ready()
      let task: Task<Void, Error>
      if let existing = warmupTask {
        task = existing
      } else {
        task = Task {
          try Task.checkCancellation()
          let conversation = try await engine.createConversation()
          try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for try await _ in conversation.sendMessageStream(Message("Hi")) {
              try Task.checkCancellation()
            }
            try Task.checkCancellation()
          } onCancel: {
            do { try conversation.cancel() } catch {
              liteRTLogger.error("LiteRT warmup cancellation failed: \(String(describing: error))")
            }
          }
        }
        warmupTask = task
      }

      do {
        try await task.value
      } catch {
        if warmupTask == task { warmupTask = nil }
        throw error
      }
      try Task.checkCancellation()
    }

    func release() async {
      let loading = engineTask
      let warming = warmupTask
      loading?.cancel()
      warming?.cancel()
      if let warming { _ = await warming.result }
      if let loading { _ = await loading.result }
      if engineTask == loading { engineTask = nil }
      if warmupTask == warming { warmupTask = nil }
    }
  }

#endif
