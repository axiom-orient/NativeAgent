import CryptoKit
import Foundation

struct LEAPArtifactFile: Hashable, Sendable {
  let fileName: String
  let remoteURL: URL
  let byteCount: UInt64
  let sha256: String
}

/// Exact, modality-neutral artifact acquisition. Native LEAP never sees a
/// partially downloaded file: every file is staged, sized, hashed, and moved
/// into its final path only after verification.
enum LEAPArtifactStore {
  static func prepare(
    files: [LEAPArtifactFile],
    rootURL: URL,
    minimumFreeBytes: UInt64,
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)?
  ) async throws -> [URL] {
    try Task.checkCancellation()
    guard !files.isEmpty else { return [] }

    var paths: [URL] = []
    paths.reserveCapacity(files.count)
    for file in files {
      try Task.checkCancellation()
      let destination = rootURL.appending(path: file.fileName, directoryHint: .notDirectory)
      emit(
        progress,
        phase: .checking,
        bytes: 0,
        total: file.byteCount,
        file: file.fileName)

      if FileManager.default.fileExists(atPath: destination.path) {
        do {
          try validate(file: destination, against: file)
          emit(
            progress,
            phase: .ready,
            bytes: file.byteCount,
            total: file.byteCount,
            file: file.fileName)
          paths.append(destination)
          continue
        } catch {
          try? FileManager.default.removeItem(at: destination)
        }
      }

      // A verified cached artifact requires no new storage. Admit disk capacity
      // only when this file needs acquisition; preserve the existing 2x safety margin.
      // Per-file checking also avoids wrapping a sum of caller-provided UInt64 sizes.
      try checkDiskCapacity(
        rootURL: rootURL,
        requiredArtifactBytes: file.byteCount,
        minimumFreeBytes: minimumFreeBytes)

      // Keep one deterministic staging path per immutable artifact. This lets
      // a later process resume a partial HTTP response with a byte range while
      // keeping the final model path atomic and independently verifiable.
      let staging = rootURL.appending(
        path: ".\(file.fileName).download",
        directoryHint: .notDirectory)
      do {
        var attempt = 0
        while true {
          do {
            try await download(
              file,
              to: staging,
              progress: progress)
            break
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            guard attempt < 2 else { throw error }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
          }
        }
        let stagedBytes = try byteCount(of: staging)
        emit(
          progress,
          phase: .verifying,
          bytes: stagedBytes,
          total: file.byteCount,
          file: file.fileName)
        try validate(file: staging, against: file)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        emit(
          progress,
          phase: .ready,
          bytes: file.byteCount,
          total: file.byteCount,
          file: file.fileName)
        paths.append(destination)
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: staging)
        throw CancellationError()
      } catch {
        try? FileManager.default.removeItem(at: staging)
        throw error
      }
    }
    return paths
  }

  private static func download(
    _ file: LEAPArtifactFile,
    to staging: URL,
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)?
  ) async throws {
    let initialBytes = try byteCount(of: staging)
    emit(
      progress,
      phase: .downloading,
      bytes: initialBytes,
      total: file.byteCount,
      file: file.fileName)

    var request = URLRequest(
      url: file.remoteURL,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 60 * 60)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    if initialBytes > 0 && initialBytes < file.byteCount {
      request.setValue("bytes=\(initialBytes)-", forHTTPHeaderField: "Range")
    }

    let delegate = try LEAPStreamingDownloadDelegate(
      stagingURL: staging,
      initialBytes: initialBytes,
      expectedBytes: file.byteCount,
      progress: { bytes in
        emit(
          progress,
          phase: .downloading,
          bytes: bytes,
          total: file.byteCount,
          file: file.fileName)
      })
    let session = URLSession(
      configuration: .ephemeral,
      delegate: delegate,
      delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request)
    try await withTaskCancellationHandler {
      task.resume()
      try await delegate.wait()
    } onCancel: {
      task.cancel()
    }
  }

  private static func byteCount(of url: URL) throws -> UInt64 {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    // URL resource values can remain cached after a long-lived FileHandle
    // appends to a staging file. Ask the open file descriptor for its current
    // end offset so resume validation cannot reject a complete file as stale.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.seekToEnd()
  }

  static func validate(file url: URL, against expected: LEAPArtifactFile) throws {
    let actualBytes = try byteCount(of: url)
    let actualSHA256 = try sha256(of: url)
    guard actualBytes == expected.byteCount, actualSHA256 == expected.sha256 else {
      throw AppleLocalAILEAPError.invalidArtifact(
        expectedBytes: expected.byteCount,
        actualBytes: actualBytes,
        expectedSHA256: expected.sha256,
        actualSHA256: actualSHA256)
    }
  }

  private static func checkDiskCapacity(
    rootURL: URL,
    requiredArtifactBytes: UInt64,
    minimumFreeBytes: UInt64
  ) throws {
    let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let available = values.volumeAvailableCapacityForImportantUsage.map(UInt64.init)
    let (doubleBytes, doubleOverflow) = requiredArtifactBytes.multipliedReportingOverflow(by: 2)
    guard !doubleOverflow else {
      throw AppleLocalAILEAPError.insufficientDisk(
        requiredBytes: .max,
        availableBytes: available)
    }
    let (required, requiredOverflow) = doubleBytes.addingReportingOverflow(minimumFreeBytes)
    guard !requiredOverflow, available.map({ $0 >= required }) ?? true else {
      throw AppleLocalAILEAPError.insufficientDisk(
        requiredBytes: required,
        availableBytes: available)
    }
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func emit(
    _ progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)?,
    phase: AppleLocalAILEAPDownloadProgress.Phase,
    bytes: UInt64,
    total: UInt64,
    file: String
  ) {
    progress?(AppleLocalAILEAPDownloadProgress(
      phase: phase,
      completedBytes: bytes,
      totalBytes: total,
      currentFile: file))
  }
}

/// Streams HTTP response bytes directly to the persistent staging file. The
/// delegate is deliberately private: it is transport mechanics, not part of
/// the LEAP or Foundation Models boundary.
private final class LEAPStreamingDownloadDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let stagingURL: URL
  private let initialBytes: UInt64
  private let expectedBytes: UInt64
  private let progress: @Sendable (UInt64) -> Void
  private let progressQuantum: UInt64 = 1 * 1024 * 1024
  private let lock = NSLock()
  private var fileHandle: FileHandle?
  private var totalBytes: UInt64
  private var lastReportedBytes: UInt64
  private var completion: Result<Void, Error>?
  private var continuation: CheckedContinuation<Void, Error>?
  private var statusCode: Int?

  init(
    stagingURL: URL,
    initialBytes: UInt64,
    expectedBytes: UInt64,
    progress: @escaping @Sendable (UInt64) -> Void
  ) throws {
    self.stagingURL = stagingURL
    self.initialBytes = initialBytes
    self.expectedBytes = expectedBytes
    self.totalBytes = initialBytes < expectedBytes ? initialBytes : 0
    self.lastReportedBytes = initialBytes < expectedBytes ? initialBytes : 0
    self.progress = progress
    super.init()

    if initialBytes == 0 || initialBytes >= expectedBytes {
      FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
      self.fileHandle = try FileHandle(forWritingTo: stagingURL)
      try self.fileHandle?.truncate(atOffset: 0)
    } else {
      self.fileHandle = try FileHandle(forWritingTo: stagingURL)
      try self.fileHandle?.seekToEnd()
    }
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let completion {
        lock.unlock()
        continuation.resume(with: completion)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      finish(.failure(AppleLocalAILEAPError.downloadFailed(
        statusCode: (response as? HTTPURLResponse)?.statusCode)))
      completionHandler(.cancel)
      return
    }

    statusCode = http.statusCode
    if initialBytes > 0 && http.statusCode == 200 {
      // The server ignored Range. Restart safely rather than appending a full
      // response to the old prefix.
      do {
        try fileHandle?.close()
        FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: stagingURL)
        try fileHandle?.truncate(atOffset: 0)
        totalBytes = 0
        lastReportedBytes = 0
        progress(0)
      } catch {
        finish(.failure(error))
        completionHandler(.cancel)
        return
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try fileHandle?.write(contentsOf: data)
      lock.lock()
      totalBytes += UInt64(data.count)
      let total = totalBytes
      let shouldReport = total == expectedBytes || total >= lastReportedBytes + progressQuantum
      if shouldReport { lastReportedBytes = total }
      lock.unlock()
      guard total <= expectedBytes else {
        finish(.failure(AppleLocalAILEAPError.downloadFailed(statusCode: nil)))
        dataTask.cancel()
        return
      }
      if shouldReport { progress(total) }
    } catch {
      finish(.failure(error))
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      if (error as NSError).code == NSURLErrorCancelled {
        finish(.failure(CancellationError()))
      } else {
        finish(.failure(error))
      }
      return
    }
    guard let statusCode, (200..<300).contains(statusCode), totalBytes == expectedBytes else {
      finish(.failure(AppleLocalAILEAPError.downloadFailed(statusCode: statusCode)))
      return
    }
    finish(.success(()))
  }

  private func finish(_ result: Result<Void, Error>) {
    // Flush and close before waking the awaiting task. Validation opens a
    // separate read handle; validating while this writer is still open can
    // observe stale file-size metadata on iOS's app container filesystem.
    try? fileHandle?.synchronize()
    try? fileHandle?.close()
    fileHandle = nil
    lock.lock()
    guard completion == nil else {
      lock.unlock()
      return
    }
    completion = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
