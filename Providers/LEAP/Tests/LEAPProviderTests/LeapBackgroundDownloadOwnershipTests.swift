#if os(iOS)
import Foundation
import Testing

@testable import LEAPProvider

@Suite struct LeapBackgroundDownloadOwnershipTests {
  @Test func metadataWithoutNativeIdentityIsRejectedAndPreserved() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "leap-invalid-ownership-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try LeapBackgroundDownloadCache(directoryURL: root)
    let request = URLRequest(url: try #require(URL(string: "https://fixture.invalid/model.gguf")))
    let key = try cache.key(for: request, expectedByteCount: 4)
    let metadataURL = root.appending(path: key + ".json")
    let unownedMetadata = try JSONSerialization.data(withJSONObject: [
      "key": key, "requestURL": try #require(request.url).absoluteString,
      "expectedByteCount": 4, "state": "inFlight", "updatedAt": 1,
    ], options: [.sortedKeys])
    try unownedMetadata.write(to: metadataURL)
    #expect(throws: LEAPProvider.LeapError.nativeFailure) { try cache.record(for: key) }
    #expect(throws: LEAPProvider.LeapError.nativeFailure) {
      try cache.remove(key, taskIdentifier: 1)
    }
    #expect(try Data(contentsOf: metadataURL) == unownedMetadata)
  }

  @Test func currentInFlightOwnerRemainsBusyUntilItsPayloadCompletes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "leap-survivor-ownership-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try LeapBackgroundDownloadCache(directoryURL: root)
    let request = URLRequest(url: try #require(URL(string: "https://fixture.invalid/model.gguf")))
    let payload = Data("file".utf8)
    let size = UInt64(payload.count)
    let key = try cache.key(for: request, expectedByteCount: size)
    let metadataURL = root.appending(path: key + ".json")
    let requestURL = try #require(request.url).absoluteString
    let bundleIdentifier = try #require(Bundle.main.bundleIdentifier)
    let configuration = URLSessionConfiguration.background(withIdentifier:
      bundleIdentifier + ".leap-download-ownership-tests." + UUID().uuidString.lowercased())
    configuration.sessionSendsLaunchEvents = false
    configuration.isDiscretionary = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let survivor = session.downloadTask(with: request)
    survivor.taskDescription = key
    try cache.begin(
      key: key, taskIdentifier: survivor.taskIdentifier, request: request, expectedByteCount: size)
    let coordinator = LeapBackgroundDownloadCoordinator(cache: cache)
    // Establish real native inventory before testing reconciliation. Never resume
    // either handle: this fixture submits no local or remote network request.
    let observedTasks: [URLSessionTask] = await withCheckedContinuation { continuation in
      session.getAllTasks { continuation.resume(returning: $0) }
    }
    let inventory = observedTasks.map { task in
      "id=\(task.taskIdentifier), state=\(task.state.rawValue), key=\(task.taskDescription ?? "nil"), "
        + "url=\(task.originalRequest?.url?.absoluteString ?? "nil")"
    }
    try #require(observedTasks.contains {
      $0 is URLSessionDownloadTask && $0.taskIdentifier == survivor.taskIdentifier
        && $0.taskDescription == key && $0.originalRequest?.url?.absoluteString == requestURL
    }, "The suspended background task must be in actual getAllTasks inventory: \(inventory)")
    #expect(survivor.state == .suspended)
    await #expect(throws: LEAPProvider.LeapError.busy) {
      try await coordinator.reconcileActiveTransfer(
        key: key, request: request, expectedByteCount: size, in: session)
    }
    #expect(try cache.record(for: key)?.taskIdentifier == survivor.taskIdentifier)
    let completion = root.appending(path: "completion.bin")
    try payload.write(to: completion)
    try cache.complete(
      key: key, taskIdentifier: survivor.taskIdentifier, statusCode: 200,
      expectedByteCount: size, temporaryURL: completion)
    let destination = root.appending(path: "staging/model.gguf")
    #expect(try cache.consumeCompleted(
      key: key, request: request, expectedByteCount: size, into: destination))
    #expect(try Data(contentsOf: destination) == payload)

    let replacement = session.downloadTask(with: request)
    replacement.taskDescription = key
    try cache.begin(
      key: key, taskIdentifier: replacement.taskIdentifier, request: request, expectedByteCount: size)
    let replacementMetadata = try Data(contentsOf: metadataURL)
    #expect(try Data(contentsOf: metadataURL) == replacementMetadata)
    #expect(try cache.record(for: key)?.taskIdentifier == replacement.taskIdentifier)
    coordinator.urlSession(session, task: survivor, didCompleteWithError: URLError(.cancelled))
    #expect(try Data(contentsOf: metadataURL) == replacementMetadata)
  }

  @Test func cancelledTaskLateCallbacksPreserveReplacementAndItsValidPayload() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "leap-download-ownership-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheURL = root.appending(path: "cache", directoryHint: .isDirectory)
    let cache = try LeapBackgroundDownloadCache(directoryURL: cacheURL)
    let request = URLRequest(url: try #require(URL(string: "https://fixture.invalid/model.gguf")))
    let payload = Data("file".utf8)
    let size = UInt64(payload.count)
    let key = try cache.key(for: request, expectedByteCount: size)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    // Both native task handles remain suspended; this test submits no network I/O.
    let oldTask = session.downloadTask(with: request)
    oldTask.taskDescription = key
    let newTask = session.downloadTask(with: request)
    newTask.taskDescription = key
    #expect(oldTask.taskIdentifier != newTask.taskIdentifier)

    try cache.begin(
      key: key, taskIdentifier: oldTask.taskIdentifier, request: request, expectedByteCount: size)
    oldTask.cancel()
    try cache.remove(key, taskIdentifier: oldTask.taskIdentifier)
    try cache.begin(
      key: key, taskIdentifier: newTask.taskIdentifier, request: request, expectedByteCount: size)
    let metadataURL = cacheURL.appending(path: key + ".json")
    let replacementMetadata = try Data(contentsOf: metadataURL)

    // A relaunched adapter must make the same admission decision from real metadata.
    let recoveredCache = try LeapBackgroundDownloadCache(directoryURL: cacheURL)
    let coordinator = LeapBackgroundDownloadCoordinator(cache: recoveredCache)
    coordinator.urlSession(session, task: oldTask, didCompleteWithError: URLError(.cancelled))
    #expect(try Data(contentsOf: metadataURL) == replacementMetadata)
    #expect(try recoveredCache.record(for: key)?.taskIdentifier == newTask.taskIdentifier)

    let staleFile = root.appending(path: "stale.bin")
    try payload.write(to: staleFile)
    coordinator.urlSession(session, downloadTask: oldTask, didFinishDownloadingTo: staleFile)
    #expect(try Data(contentsOf: metadataURL) == replacementMetadata)
    #expect(try Data(contentsOf: staleFile) == payload)
    #expect(throws: LEAPProvider.LeapError.nativeFailure) {
      try recoveredCache.complete(
        key: key, taskIdentifier: oldTask.taskIdentifier, statusCode: 200,
        expectedByteCount: size, temporaryURL: staleFile)
    }
    #expect(try Data(contentsOf: metadataURL) == replacementMetadata)

    let newFile = root.appending(path: "new.bin")
    let destination = root.appending(path: "staging/model.gguf")
    try payload.write(to: newFile)
    try recoveredCache.complete(
      key: key, taskIdentifier: newTask.taskIdentifier, statusCode: 200,
      expectedByteCount: size, temporaryURL: newFile)
    // Even after publication to the recovery cache, an old error cannot remove it.
    coordinator.urlSession(session, task: oldTask, didCompleteWithError: URLError(.cancelled))
    #expect(try recoveredCache.consumeCompleted(
      key: key, request: request, expectedByteCount: size, into: destination))
    #expect(try Data(contentsOf: destination) == payload)
    #expect(try recoveredCache.record(for: key) == nil)
    #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
  }

  @Test func currentNativeCompletionAdmitsOnlyItsRecordedOwner() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "leap-early-callback-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try LeapBackgroundDownloadCache(directoryURL: root)
    let request = URLRequest(url: try #require(URL(string: "https://fixture.invalid/model.gguf")))
    let payload = Data("file".utf8)
    let size = UInt64(payload.count)
    let key = try cache.key(for: request, expectedByteCount: size)
    let metadataURL = root.appending(path: key + ".json")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let survivor = session.downloadTask(with: request)
    survivor.taskDescription = key
    try cache.begin(
      key: key, taskIdentifier: survivor.taskIdentifier, request: request, expectedByteCount: size)
    let ownerMetadata = try Data(contentsOf: metadataURL)
    let coordinator = LeapBackgroundDownloadCoordinator(cache: cache)
    let completion = root.appending(path: "completion.bin")
    try payload.write(to: completion)

    let unrelatedRequest = URLRequest(
      url: try #require(URL(string: "https://fixture.invalid/unrelated.gguf")))
    let unrelated = session.downloadTask(with: unrelatedRequest)
    unrelated.taskDescription = key
    coordinator.finishOrphan(downloadTask: unrelated, statusCode: 200, location: completion)
    #expect(try Data(contentsOf: metadataURL) == ownerMetadata)
    #expect(try Data(contentsOf: completion) == payload)

    // Exercise the delegate's synchronous orphan handler with a real native
    // task and a fixture HTTP status; no task response is overridden and no I/O
    // is submitted. This proves callback admission and file preservation only.
    coordinator.finishOrphan(downloadTask: survivor, statusCode: 200, location: completion)
    #expect(try cache.record(for: key)?.taskIdentifier == survivor.taskIdentifier)
    #expect(!FileManager.default.fileExists(atPath: completion.path))
    #expect(try Data(contentsOf: root.appending(path: key + ".payload")) == payload)
    let destination = root.appending(path: "staging/model.gguf")
    #expect(try cache.consumeCompleted(
      key: key, request: request, expectedByteCount: size, into: destination))
    #expect(try Data(contentsOf: destination) == payload)
    #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
  }
}
#endif
