import ModelArtifactStore
import CryptoKit
import Foundation

public struct LeapDownloadProgress: Hashable, Sendable {
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let currentFile: String?
}

protocol LeapDownloading: Sendable {
  func download(
    repositoryID: String,
    revision: String,
    manifest: ArtifactManifest,
    into staging: ArtifactStaging,
    progress: (@Sendable (LeapDownloadProgress) -> Void)?
  ) async throws
}

enum LeapDownloadValidation {
  static func validate(
    statusCode: Int?,
    isRegularFile: Bool?,
    fileSize: Int64?,
    expectedByteCount: UInt64
  ) throws {
    guard statusCode == 200 else { throw LeapError.nativeFailure }
    guard isRegularFile == true,
      let fileSize,
      fileSize >= 0,
      UInt64(fileSize) == expectedByteCount
    else { throw LeapError.invalidArtifact }
  }
}

/// One terminal path owns a URLSession task.  The delegate may receive a
/// completion and a cancellation concurrently, so the worker which moved the
/// temporary file asks this gate whether cancellation won before it exposes a
/// file to staging.  The gate deliberately has no policy beyond that race.
final class LeapDownloadTerminalGate: @unchecked Sendable {
  enum Resolution: Equatable { case success, cancelled }

  private enum State { case waiting, finishing, cancelled, resolved }
  private let lock = NSLock()
  private var state: State = .waiting

  func beginFinishing() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == .waiting else { return false }
    state = .finishing
    return true
  }

  /// Returns true when the caller must immediately resume a still-waiting
  /// continuation with cancellation.  A finishing delegate owns the eventual
  /// continuation and receives the cancelled resolution from `resolve()`.
  func requestCancellation() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .waiting:
      state = .resolved
      return true
    case .finishing:
      state = .cancelled
      return false
    case .cancelled, .resolved:
      return false
    }
  }

  func resolve() -> Resolution? {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .finishing:
      state = .resolved
      return .success
    case .cancelled:
      state = .resolved
      return .cancelled
    case .waiting, .resolved:
      return nil
    }
  }
}

enum LeapDownloadFileCommit {
  static func moveValidatedResponse(
    from source: URL,
    statusCode: Int?,
    expectedByteCount: UInt64,
    to destination: URL
  ) throws {
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    try LeapDownloadValidation.validate(
      statusCode: statusCode,
      isRegularFile: values.isRegularFile,
      fileSize: values.fileSize.map(Int64.init),
      expectedByteCount: expectedByteCount)
    try moveExistingFile(from: source, expectedByteCount: expectedByteCount, to: destination)
  }

  static func moveExistingFile(
    from source: URL,
    expectedByteCount: UInt64,
    to destination: URL
  ) throws {
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    try LeapDownloadValidation.validate(
      statusCode: 200,
      isRegularFile: values.isRegularFile,
      fileSize: values.fileSize.map(Int64.init),
      expectedByteCount: expectedByteCount)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: source, to: destination)
  }
}

enum LeapDownloadProgressAggregation {
  static func aggregate(
    completedBytes: UInt64,
    fileBytesWritten: UInt64,
    fileByteCount: UInt64,
    totalBytes: UInt64
  ) -> UInt64? {
    guard fileBytesWritten <= fileByteCount else { return nil }
    let (aggregate, overflow) = completedBytes.addingReportingOverflow(fileBytesWritten)
    guard !overflow, aggregate <= totalBytes else { return nil }
    return aggregate
  }
}

#if DEBUG
/// Device-harness-only fault localization.  Public API and runtime error
/// mapping stay unchanged; the record is overwritten on every boundary so a
/// failed physical transfer can identify the exact non-publishing stage.
enum LeapDownloadDebug {
  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var failure: String?
  }

  private static let storage = Storage()

  static var lastFailure: String? {
    storage.lock.lock()
    defer { storage.lock.unlock() }
    return storage.failure
  }

  static func record(_ stage: String, error: any Error) {
    storage.lock.lock()
    storage.failure = "\(stage): \(String(describing: error))"
    storage.lock.unlock()
  }

  static func clear() {
    storage.lock.lock()
    storage.failure = nil
    storage.lock.unlock()
  }
}
#endif

struct LeapHTTPDownloader: LeapDownloading {
  func download(
    repositoryID: String,
    revision: String,
    manifest: ArtifactManifest,
    into staging: ArtifactStaging,
    progress: (@Sendable (LeapDownloadProgress) -> Void)?
  ) async throws {
    let largest = manifest.files.map(\.byteCount).max() ?? 0
    let available = try staging.directoryURL.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage
    let (required, overflow) = manifest.totalBytes.addingReportingOverflow(largest)
    guard !overflow, let available, available >= 0, UInt64(available) >= required else {
      throw LeapError.insufficientDisk
    }

    var completed: UInt64 = 0
    var destinations: [URL] = []
    do {
      progress?(
        .init(completedBytes: 0, totalBytes: manifest.totalBytes, currentFile: nil))
      for file in manifest.files {
        try Task.checkCancellation()
        progress?(
          .init(
            completedBytes: completed, totalBytes: manifest.totalBytes,
            currentFile: file.path))
        guard
          let url = URL(
            string:
              "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(file.path)"
          )
        else { throw LeapError.invalidArtifact }
        let destination = staging.directoryURL.appending(path: file.path)
        destinations.append(destination)
        let fileBase = completed
        let fileProgress: @Sendable (UInt64) -> Void = { written in
          guard let value = LeapDownloadProgressAggregation.aggregate(
            completedBytes: fileBase,
            fileBytesWritten: written,
            fileByteCount: file.byteCount,
            totalBytes: manifest.totalBytes)
          else { return }
          progress?(
            .init(
              completedBytes: value, totalBytes: manifest.totalBytes,
              currentFile: file.path))
        }
        #if os(iOS)
          try await LeapBackgroundDownloadCoordinator.shared.download(
            request: URLRequest(url: url),
            expectedByteCount: file.byteCount,
            destinationURL: destination,
            progress: fileProgress)
        #else
          let configuration = URLSessionConfiguration.ephemeral
          configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
          configuration.timeoutIntervalForRequest = 120
          configuration.timeoutIntervalForResource = 7_200
          let session = URLSession(configuration: configuration)
          let (temporary, response) = try await session.download(from: url)
          try LeapDownloadFileCommit.moveValidatedResponse(
            from: temporary,
            statusCode: (response as? HTTPURLResponse)?.statusCode,
            expectedByteCount: file.byteCount,
            to: destination)
        #endif
        try Task.checkCancellation()
        completed += file.byteCount
      }
      progress?(
        .init(
          completedBytes: completed, totalBytes: manifest.totalBytes,
          currentFile: nil))
    } catch {
      try removeDownloadedFiles(destinations)
      throw error
    }
  }

  private func removeDownloadedFiles(_ destinations: [URL]) throws {
    var cleanupFailure: (any Error)?
    for destination in destinations.reversed() where FileManager.default.fileExists(
      atPath: destination.path)
    {
      do {
        try FileManager.default.removeItem(at: destination)
      } catch {
        cleanupFailure = error
      }
    }
    if cleanupFailure != nil { throw LeapError.nativeFailure }
  }
}

#if os(iOS)
private struct LeapBackgroundTransferRecord: Codable {
  // Metadata only identifies an active task after a process restart.  It is
  // deliberately not the authority for a completed response: a process can
  // die after the validated payload rename and before this tiny JSON write.
  enum State: String, Codable { case inFlight }

  let key: String
  let requestURL: String
  let expectedByteCount: UInt64
  var state: State
  var updatedAt: TimeInterval
}

/// A recovery cache is intentionally outside ModelArtifactStore.  A background
/// session can outlive the process which owns an `ArtifactStaging` object;
/// persisting a completed *verified-by-size* file here lets a later explicit
/// `prepare` move it into a new staging transaction, where ArtifactStore still
/// performs the authoritative digest verification and atomic publish.
private final class LeapBackgroundDownloadCache: @unchecked Sendable {
  private static let directoryName = "LEAPProvider.background-downloads.v1"
  private static let maximumCompletedTransfers = 4

  private let fileManager = FileManager.default
  private let directoryURL: URL
  private let lock = NSLock()

  init() throws {
    let caches = try fileManager.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    directoryURL = caches.appending(path: Self.directoryName, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  func key(for request: URLRequest, expectedByteCount: UInt64) throws -> String {
    guard let url = request.url, url.scheme == "https", url.host != nil else {
      throw LeapError.invalidArtifact
    }
    let material = url.absoluteString + "\u{0}" + String(expectedByteCount)
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func consumeCompleted(
    key: String,
    request: URLRequest,
    expectedByteCount: UInt64,
    into destinationURL: URL
  ) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let payload = payloadURL(for: key)
    // The deterministic key binds this payload to the current HTTPS URL and
    // exact expected byte count.  ArtifactStore still verifies the digest
    // after this move.  Therefore a full regular payload is recoverable even
    // when the process was killed between its atomic rename and metadata I/O.
    if isExpectedFile(payload, expectedByteCount: expectedByteCount) {
      do {
        try LeapDownloadFileCommit.moveExistingFile(
          from: payload,
          expectedByteCount: expectedByteCount,
          to: destinationURL)
      } catch {
        #if DEBUG
        LeapDownloadDebug.record("recovery-cache-to-staging", error: error)
        #endif
        throw error
      }
      try removeLocked(key)
      return true
    }
    if fileManager.fileExists(atPath: payload.path) {
      // A malformed/truncated orphan must never be mistaken for a complete
      // response.  Drop it before a later explicit download creates a task.
      try removeLocked(key)
      return false
    }
    if let record = try read(key), !recordMatches(record, request, expectedByteCount) {
      // The key is derived from the current request, so mismatched advisory
      // metadata is corrupt state rather than a recoverable active transfer.
      try removeLocked(key)
    }
    return false
  }

  func hasActiveTransfer(
    key: String,
    request: URLRequest,
    expectedByteCount: UInt64
  ) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if isExpectedFile(payloadURL(for: key), expectedByteCount: expectedByteCount) {
      return false
    }
    guard let record = try read(key), recordMatches(record, request, expectedByteCount) else {
      return false
    }
    return record.state == .inFlight
  }

  func begin(
    key: String,
    request: URLRequest,
    expectedByteCount: UInt64
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let payload = payloadURL(for: key)
    if fileManager.fileExists(atPath: payload.path) {
      guard !isExpectedFile(payload, expectedByteCount: expectedByteCount) else {
        throw LeapError.busy
      }
      try removeLocked(key)
    }
    if let record = try read(key) {
      guard recordMatches(record, request, expectedByteCount) else {
        throw LeapError.nativeFailure
      }
      throw LeapError.busy
    }
    try write(
      .init(
        key: key,
        requestURL: request.url!.absoluteString,
        expectedByteCount: expectedByteCount,
        state: .inFlight,
        updatedAt: Date().timeIntervalSince1970))
  }

  func complete(
    key: String,
    statusCode: Int?,
    expectedByteCount: UInt64,
    temporaryURL: URL
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let record = try read(key), record.expectedByteCount == expectedByteCount,
      record.state == .inFlight
    else { throw LeapError.nativeFailure }
    do {
      try LeapDownloadFileCommit.moveValidatedResponse(
        from: temporaryURL,
        statusCode: statusCode,
        expectedByteCount: expectedByteCount,
        to: payloadURL(for: key))
    } catch {
      #if DEBUG
        LeapDownloadDebug.record("background-temporary-to-recovery-cache", error: error)
      #endif
      throw error
    }
    try trimCompleted(preserving: key)
  }

  func remove(_ key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    try removeLocked(key)
  }

  private func removeLocked(_ key: String) throws {
    let metadata = metadataURL(for: key)
    let payload = payloadURL(for: key)
    if fileManager.fileExists(atPath: metadata.path) {
      try fileManager.removeItem(at: metadata)
    }
    if fileManager.fileExists(atPath: payload.path) {
      try fileManager.removeItem(at: payload)
    }
  }

  private func trimCompleted(preserving key: String) throws {
    let urls = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles])
    let payloads = try urls.compactMap { url -> (key: String, date: Date)? in
      guard url.pathExtension == "payload" else { return nil }
      let key = url.deletingPathExtension().lastPathComponent
      guard isSafeKey(key),
        (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
      else { return nil }
      let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
      return (key, values.contentModificationDate ?? .distantPast)
    }
    let overflow = max(0, payloads.count - Self.maximumCompletedTransfers)
    for payload in payloads
      .filter({ $0.key != key })
      .sorted(by: { $0.date < $1.date })
      .prefix(overflow)
    {
      try removeLocked(payload.key)
    }
  }

  private func read(_ key: String) throws -> LeapBackgroundTransferRecord? {
    guard isSafeKey(key) else { throw LeapError.nativeFailure }
    let url = metadataURL(for: key)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let record = try JSONDecoder().decode(LeapBackgroundTransferRecord.self, from: Data(contentsOf: url))
      guard record.key == key, isSafeKey(record.key) else { throw LeapError.nativeFailure }
      return record
    } catch {
      if fileManager.fileExists(atPath: url.path) {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          throw LeapError.nativeFailure
        }
      }
      // Metadata is advisory recovery state.  A malformed record cannot
      // publish anything; discard it so a later explicit prepare can use an
      // exact payload or create a new task.
      return nil
    }
  }

  private func write(_ record: LeapBackgroundTransferRecord) throws {
    guard isSafeKey(record.key) else { throw LeapError.nativeFailure }
    try JSONEncoder().encode(record).write(to: metadataURL(for: record.key), options: .atomic)
  }

  private func recordMatches(
    _ record: LeapBackgroundTransferRecord,
    _ request: URLRequest,
    _ expectedByteCount: UInt64
  ) -> Bool {
    record.requestURL == request.url?.absoluteString && record.expectedByteCount == expectedByteCount
  }

  private func metadataURL(for key: String) -> URL {
    directoryURL.appending(path: key + ".json")
  }

  private func payloadURL(for key: String) -> URL {
    directoryURL.appending(path: key + ".payload")
  }

  private func isExpectedFile(_ url: URL, expectedByteCount: UInt64) -> Bool {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      return false
    }
    return values.isRegularFile == true && values.fileSize.map(UInt64.init) == expectedByteCount
  }

  private func isSafeKey(_ key: String) -> Bool {
    key.utf8.count == 64 && key.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}

/// Hosts must forward `UIApplicationDelegate` background-session events here.
/// The hook recreates the stable app-scoped session after a relaunch so its
/// delegate can validate and preserve an orphaned completed download.  It does
/// not publish an artifact or invent a continuation; the next explicit
/// `prepare` consumes the recovered cache into a fresh staging transaction.
public enum LeapBackgroundDownloads {
  public static var sessionIdentifier: String? {
    LeapBackgroundDownloadCoordinator.sessionIdentifier
  }

  public static func handleEvents(
    for identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    LeapBackgroundDownloadCoordinator.shared.handleEvents(
      for: identifier,
      completionHandler: completionHandler)
  }
}

private final class LeapBackgroundDownloadCoordinator: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  static let shared = LeapBackgroundDownloadCoordinator()

  static var sessionIdentifier: String? {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
      return nil
    }
    return bundleIdentifier + ".nativeagent.leap.downloads.v1"
  }

  private struct Pending {
    let task: URLSessionDownloadTask
    let continuation: CheckedContinuation<Void, any Error>
    let key: String
    let request: URLRequest
    let destinationURL: URL
    let expectedByteCount: UInt64
    let progress: (@Sendable (UInt64) -> Void)?
    let gate = LeapDownloadTerminalGate()
  }

  /// UIKit owns this completion and requires it on the main queue. The box
  /// crosses the URLSession delegate queue only while protected by `lock`; it
  /// is invoked exactly once after dispatching back to main.
  private final class BackgroundEventsCompletion: @unchecked Sendable {
    private let value: () -> Void

    init(_ value: @escaping () -> Void) {
      self.value = value
    }

    func invoke() {
      value()
    }
  }

  private let lock = NSLock()
  private var backgroundSession: URLSession?
  private var downloadCache: LeapBackgroundDownloadCache?
  private var pending: [Int: Pending] = [:]
  private var finishing: [Int: Pending] = [:]
  private var backgroundEventsCompletion: BackgroundEventsCompletion?

  private override init() { super.init() }

  func download(
    request: URLRequest,
    expectedByteCount: UInt64,
    destinationURL: URL,
    progress: (@Sendable (UInt64) -> Void)?
  ) async throws {
    try Task.checkCancellation()
    let session = try urlSession()
    let cache = try cacheStore()
    let key = try cache.key(for: request, expectedByteCount: expectedByteCount)

    if try cache.consumeCompleted(
      key: key,
      request: request,
      expectedByteCount: expectedByteCount,
      into: destinationURL)
    {
      return
    }

    if try cache.hasActiveTransfer(key: key, request: request, expectedByteCount: expectedByteCount) {
      if await hasSessionTask(withKey: key, in: session) { throw LeapError.busy }
      // A process can die after the OS has discarded a failed task but before
      // its error delegate runs.  No payload exists, so a new explicit prepare
      // starts a new background task rather than pretending this one resumed.
      try cache.remove(key)
    }

    let task = session.downloadTask(with: request)
    task.taskDescription = key
    try cache.begin(key: key, request: request, expectedByteCount: expectedByteCount)
    try await awaitTask(
      task,
      key: key,
      request: request,
      destinationURL: destinationURL,
      expectedByteCount: expectedByteCount,
      progress: progress)
  }

  func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) {
    guard identifier == Self.sessionIdentifier else {
      completionHandler()
      return
    }
    let completion = BackgroundEventsCompletion(completionHandler)
    do {
      lock.lock()
      let previous = backgroundEventsCompletion
      backgroundEventsCompletion = completion
      lock.unlock()
      _ = try urlSession()
      dispatchOnMain(previous)
    } catch {
      lock.lock()
      let stored = backgroundEventsCompletion
      if stored != nil { backgroundEventsCompletion = nil }
      lock.unlock()
      dispatchOnMain(stored ?? completion)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten >= 0 else { return }
    let callback: (@Sendable (UInt64) -> Void)?
    lock.lock()
    callback = pending[downloadTask.taskIdentifier]?.progress
    lock.unlock()
    callback?(UInt64(totalBytesWritten))
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let taskIdentifier = downloadTask.taskIdentifier
    let record: Pending?
    lock.lock()
    if let current = pending.removeValue(forKey: taskIdentifier), current.gate.beginFinishing() {
      finishing[taskIdentifier] = current
      record = current
    } else if finishing[taskIdentifier] != nil {
      record = nil // Duplicate finish callback; its first terminal path owns the location.
    } else {
      record = nil
    }
    lock.unlock()

    if let record {
      finishOwned(
        record,
        taskIdentifier: taskIdentifier,
        statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode,
        location: location)
      return
    }
    finishOrphan(
      taskDescription: downloadTask.taskDescription,
      statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode,
      location: location)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    guard let error else { return }
    let record: Pending?
    lock.lock()
    record = pending.removeValue(forKey: task.taskIdentifier)
    let isFinishing = finishing[task.taskIdentifier] != nil
    lock.unlock()
    if let record {
      _ = record.gate.requestCancellation()
      task.cancel()
      let result: Result<Void, any Error>
      do {
        try cacheStore().remove(record.key)
        result = .failure(error)
      } catch {
        result = .failure(LeapError.nativeFailure)
      }
      record.continuation.resume(with: result)
    } else if !isFinishing {
      failOrphan(taskDescription: task.taskDescription)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completion: BackgroundEventsCompletion?
    lock.lock()
    completion = backgroundEventsCompletion
    backgroundEventsCompletion = nil
    lock.unlock()
    dispatchOnMain(completion)
  }

  private func dispatchOnMain(_ completion: BackgroundEventsCompletion?) {
    guard let completion else { return }
    DispatchQueue.main.async {
      completion.invoke()
    }
  }

  private func awaitTask(
    _ task: URLSessionDownloadTask,
    key: String,
    request: URLRequest,
    destinationURL: URL,
    expectedByteCount: UInt64,
    progress: (@Sendable (UInt64) -> Void)?
  ) async throws {
    let taskIdentifier = task.taskIdentifier
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        let record = Pending(
          task: task,
          continuation: continuation,
          key: key,
          request: request,
          destinationURL: destinationURL,
          expectedByteCount: expectedByteCount,
          progress: progress)
        lock.lock()
        let cancelledBeforeRegistration = Task.isCancelled
        if !cancelledBeforeRegistration { pending[taskIdentifier] = record }
        lock.unlock()
        if cancelledBeforeRegistration {
          task.cancel()
          do { try cacheStore().remove(key) } catch {
            continuation.resume(throwing: LeapError.nativeFailure)
            return
          }
          continuation.resume(throwing: CancellationError())
        } else {
          task.resume()
        }
      }
    }, onCancel: { [weak self] in
      self?.cancel(taskIdentifier: taskIdentifier)
    })
  }

  private func finishOwned(
    _ record: Pending,
    taskIdentifier: Int,
    statusCode: Int?,
    location: URL
  ) {
    let result: Result<Void, any Error>
    do {
      let cache = try cacheStore()
      try cache.complete(
        key: record.key,
        statusCode: statusCode,
        expectedByteCount: record.expectedByteCount,
        temporaryURL: location)
      guard let resolution = record.gate.resolve() else { return }
      switch resolution {
      case .cancelled:
        result = .failure(CancellationError())
      case .success:
        guard try cache.consumeCompleted(
          key: record.key,
          request: record.request,
          expectedByteCount: record.expectedByteCount,
          into: record.destinationURL)
        else { throw LeapError.nativeFailure }
        result = .success(())
      }
    } catch {
      _ = record.gate.resolve()
      result = .failure(error)
    }
    lock.lock()
    finishing.removeValue(forKey: taskIdentifier)
    lock.unlock()
    record.continuation.resume(with: result)
  }

  private func finishOrphan(taskDescription: String?, statusCode: Int?, location: URL) {
    guard let key = taskDescription, isSafeKey(key) else { return }
    do {
      let cache = try cacheStore()
      guard let record = try cache.record(for: key), record.state == .inFlight else { return }
      try cache.complete(
        key: key,
        statusCode: statusCode,
        expectedByteCount: record.expectedByteCount,
        temporaryURL: location)
    } catch {
      do {
        try cacheStore().remove(key)
      } catch {
        // No caller continuation remains after an orphan callback.  Leaving
        // its metadata untrusted only forces a later explicit prepare to
        // discard/restart; it can never reach artifact publish from here.
      }
    }
  }

  private func failOrphan(taskDescription: String?) {
    guard let key = taskDescription, isSafeKey(key) else { return }
    do {
      let cache = try cacheStore()
      guard let record = try cache.record(for: key), record.state == .inFlight else { return }
      try cache.remove(key)
    } catch {}
  }

  private func cancel(taskIdentifier: Int) {
    let record: Pending?
    lock.lock()
    if let pendingRecord = pending.removeValue(forKey: taskIdentifier) {
      record = pendingRecord
    } else {
      record = finishing[taskIdentifier]
    }
    lock.unlock()
    guard let record else { return }
    record.task.cancel()
    if record.gate.requestCancellation() {
      let result: Result<Void, any Error>
      do {
        try cacheStore().remove(record.key)
        result = .failure(CancellationError())
      } catch {
        result = .failure(LeapError.nativeFailure)
      }
      record.continuation.resume(with: result)
    }
  }

  private func hasSessionTask(withKey key: String, in session: URLSession) async -> Bool {
    await withCheckedContinuation { continuation in
      session.getAllTasks { tasks in
        continuation.resume(returning: tasks.contains { $0.taskDescription == key })
      }
    }
  }

  private func urlSession() throws -> URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let backgroundSession { return backgroundSession }
    guard let identifier = Self.sessionIdentifier else { throw LeapError.nativeFailure }
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 7_200
    configuration.waitsForConnectivity = true
    configuration.isDiscretionary = false
    configuration.sessionSendsLaunchEvents = true
    let delegateQueue = OperationQueue()
    delegateQueue.name = "com.axiomorient.nativeagent.leap.download-delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    let created = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    backgroundSession = created
    return created
  }

  private func cacheStore() throws -> LeapBackgroundDownloadCache {
    lock.lock()
    defer { lock.unlock() }
    if let downloadCache { return downloadCache }
    let created = try LeapBackgroundDownloadCache()
    downloadCache = created
    return created
  }

  private func isSafeKey(_ key: String) -> Bool {
    key.utf8.count == 64 && key.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}

private extension LeapBackgroundDownloadCache {
  func record(for key: String) throws -> LeapBackgroundTransferRecord? {
    lock.lock()
    defer { lock.unlock() }
    return try read(key)
  }
}
#else
public enum LeapBackgroundDownloads {
  public static var sessionIdentifier: String? { nil }

  public static func handleEvents(
    for identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}
#endif
