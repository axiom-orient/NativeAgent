import Foundation
import Testing

@testable import MLXProvider

/// Tests the actual completion cell, not native model inference.
@Suite struct MLXResultHandleTests {
  private struct Payload: Sendable, Equatable { let id: Int }
  private struct Failure: Error {}

  @Test func pendingResultIsAbsent() {
    let handle = MLXResultHandle<Payload>()
    #expect(handle.result() == nil)
  }

  @Test func nonVoidLoadPayloadIsPreserved() throws {
    let handle = MLXResultHandle<Payload>()
    #expect(!handle.finish(.success(Payload(id: 42))))
    let result = try #require(handle.result())
    #expect(try result.get() == Payload(id: 42))
  }

  @Test func firstCompletionCannotBeOverwritten() throws {
    let handle = MLXResultHandle<Payload>()
    #expect(!handle.finish(.success(Payload(id: 7))))
    #expect(!handle.finish(.failure(Failure())))
    #expect(try #require(handle.result()).get() == Payload(id: 7))
  }

  @Test func failureRemainsFailure() throws {
    let handle = MLXResultHandle<Payload>()
    handle.finish(.failure(Failure()))
    handle.finish(.success(Payload(id: 8)))
    guard case .failure(let error) = try #require(handle.result()) else {
      Issue.record("An earlier failure was overwritten.")
      return
    }
    #expect(error is Failure)
  }

  @Test func quarantinedCompletionRequestsCleanupAndPublishesCancellation() throws {
    let handle = MLXResultHandle<Payload>()
    #expect(handle.quarantine())
    #expect(handle.result() == nil)
    #expect(handle.finish(.success(Payload(id: 8))))
    #expect(!handle.finish(.success(Payload(id: 9))))
    guard case .failure(let error) = try #require(handle.result()) else {
      Issue.record("A quarantined value escaped to the caller.")
      return
    }
    #expect(error is CancellationError)
  }

  @Test func completedValueCannotBeQuarantinedRetroactively() throws {
    let handle = MLXResultHandle<Payload>()
    handle.finish(.success(Payload(id: 9)))
    #expect(!handle.quarantine())
    #expect(try #require(handle.result()).get() == Payload(id: 9))
  }

  @Test func concurrentReadersAndCompletionsKeepOneTerminalValue() async throws {
    let handle = MLXResultHandle<Payload>()
    await withTaskGroup(of: Void.self) { group in
      for id in 0..<64 {
        group.addTask {
          handle.finish(.success(Payload(id: id)))
          _ = handle.result()
        }
      }
    }
    let first = try #require(handle.result()).get()
    #expect((0..<64).contains(first.id))
    for id in 64..<128 { handle.finish(.success(Payload(id: id))) }
    #expect(try #require(handle.result()).get() == first)
  }
}
