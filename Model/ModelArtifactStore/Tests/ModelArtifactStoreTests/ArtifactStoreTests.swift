import CryptoKit
import Foundation
import XCTest

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@testable import ModelArtifactStore

final class ModelArtifactStoreTests: XCTestCase {
  func testDecodedEntryCannotBypassPathValidation() throws {
    let valid = try entry("model.bin", "model")
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    for path in ["../escape", "/absolute", ".native-agent-stage.lock", "a//b"] {
      payload["path"] = path
      let data = try JSONSerialization.data(withJSONObject: payload)
      XCTAssertThrowsError(try JSONDecoder().decode(ArtifactEntry.self, from: data), path)
    }
  }

  func testDecodedManifestMustBeCurrentAndSelfConsistent() throws {
    let valid = try ArtifactManifest(artifactID: "model", files: [entry("model.bin", "model")])
    let encoded = try JSONEncoder().encode(valid)
    XCTAssertEqual(try JSONDecoder().decode(ArtifactManifest.self, from: encoded), valid)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for (key, value) in [("formatVersion", 0), ("formatVersion", 2), ("totalBytes", 0)] {
      var invalid = payload
      invalid[key] = value
      XCTAssertThrowsError(try JSONDecoder().decode(
        ArtifactManifest.self, from: JSONSerialization.data(withJSONObject: invalid)))
    }
    var missingVersion = payload
    missingVersion.removeValue(forKey: "formatVersion")
    XCTAssertThrowsError(try JSONDecoder().decode(
      ArtifactManifest.self, from: JSONSerialization.data(withJSONObject: missingVersion)))
    var wrongDigest = payload
    wrongDigest["manifestDigest"] = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(digest("different namespace")), options: .fragmentsAllowed)
    XCTAssertThrowsError(try JSONDecoder().decode(
      ArtifactManifest.self, from: JSONSerialization.data(withJSONObject: wrongDigest)))
  }

  func testArtifactIDCannotNameFilesystemTraversalComponents() throws {
    let file = try entry("model.bin", "model")
    XCTAssertThrowsError(try ArtifactManifest(artifactID: ".", files: [file]))
    XCTAssertThrowsError(try ArtifactManifest(artifactID: "..", files: [file]))
    XCTAssertNoThrow(try ArtifactManifest(artifactID: "model.v1", files: [file]))
  }

  func testProcessResidencyRejectsDuplicateNativeOwners() throws {
    let first = try ProcessResidency.shared.claim()
    defer { first.close() }
    XCTAssertThrowsError(try ProcessResidency.shared.claim()) { error in
      XCTAssertEqual(error as? ProcessResidencyError, .busy)
    }
  }

  func testManifestIsDeterministicAndStrict() throws {
    let first = try entry("a.bin", "a")
    let second = try entry("dir/b.bin", "bb")
    let a = try ArtifactManifest(artifactID: "model-1", files: [first, second])
    let b = try ArtifactManifest(artifactID: "model-1", files: [first, second])
    XCTAssertEqual(a, b)
    XCTAssertThrowsError(try ArtifactManifest(artifactID: "model-1", files: [second, first]))
    XCTAssertThrowsError(try ArtifactManifest(artifactID: "model-1", files: [first, first]))
    let composed = try ArtifactEntry(path: "é", byteCount: 1, sha256: digest("a"))
    let decomposed = try ArtifactEntry(path: "e\u{301}", byteCount: 1, sha256: digest("a"))
    let equivalentPaths = [composed, decomposed].sorted {
      $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
    }
    XCTAssertThrowsError(
      try ArtifactManifest(artifactID: "model-1", files: equivalentPaths)
    )
    XCTAssertThrowsError(try ArtifactEntry(path: "../escape", byteCount: 1, sha256: digest("a")))
    XCTAssertThrowsError(
      try ArtifactEntry(path: ".native-agent-hidden", byteCount: 1, sha256: digest("a")))
  }

  func testPublishOpenLeaseAndRemoveAcrossStores() async throws {
    let root = try temporaryDirectory()
    let storeA = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let storeB = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(artifactID: "text", files: [entry("model.bin", "model")])
    let staging = try await storeA.beginStaging(for: manifest)
    try Data("model".utf8).write(to: staging.directoryURL.appending(path: "model.bin"))
    let lease = try await storeA.publish(staging)
    XCTAssertEqual(
      try Data(contentsOf: lease.directoryURL.appending(path: "model.bin")), Data("model".utf8))
    do {
      try await storeB.remove(manifest)
      XCTFail("active cross-process-style lease must block removal")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .busy) }
    lease.close()
    try await storeB.remove(manifest)
    do {
      _ = try await storeA.open(manifest)
      XCTFail("removed snapshot must be missing")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .missingFile) }
  }

  func testPublishVerifiesNewSnapshotExactlyOnce() async throws {
    let root = try temporaryDirectory()
    let verifier = VerificationCounter()
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 0,
      availableBytes: { _ in UInt64.max },
      verificationObserver: { verifier.increment() })
    let manifest = try ArtifactManifest(artifactID: "text", files: [entry("model.bin", "model")])
    let staging = try await store.beginStaging(for: manifest)
    try Data("model".utf8).write(to: staging.directoryURL.appending(path: "model.bin"))

    let lease = try await store.publish(staging)
    XCTAssertEqual(verifier.value, 1)
    XCTAssertEqual(
      try Data(contentsOf: lease.directoryURL.appending(path: "model.bin")), Data("model".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directoryURL.path))
    XCTAssertThrowsError(try staging.importFiles(from: root)) { error in
      XCTAssertEqual(error as? ArtifactStoreError, .consumedStaging)
    }
    lease.close()
  }

  func testPublishDeduplicatedSnapshotVerifiesExistingArtifactOnceAndReturnsLease() async throws {
    let root = try temporaryDirectory()
    let verifier = VerificationCounter()
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 0,
      availableBytes: { _ in UInt64.max },
      verificationObserver: { verifier.increment() })
    let manifest = try ArtifactManifest(artifactID: "text", files: [entry("model.bin", "model")])

    var staging = try await store.beginStaging(for: manifest)
    try Data("model".utf8).write(to: staging.directoryURL.appending(path: "model.bin"))
    let initial = try await store.publish(staging)
    initial.close()

    staging = try await store.beginStaging(for: manifest)
    try Data("model".utf8).write(to: staging.directoryURL.appending(path: "model.bin"))
    let deduplicated = try await store.publish(staging)
    XCTAssertEqual(verifier.value, 2)
    XCTAssertEqual(
      try Data(contentsOf: deduplicated.directoryURL.appending(path: "model.bin")), Data("model".utf8))
    deduplicated.close()
  }

  func testPublishSynchronizesNestedDirectoriesAndRenameParentsBeforeLeasing() async throws {
    let root = try temporaryDirectory()
    let synchronization = DirectorySynchronizationProbe()
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 0, availableBytes: { _ in UInt64.max },
      synchronizeDirectory: { try synchronization.synchronize($0) })
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [entry("nested/weight.bin", "verified")])
    let staging = try await store.beginStaging(for: manifest)
    let nested = staging.directoryURL.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    try Data("verified".utf8).write(to: nested.appending(path: "weight.bin"))
    let nestedIdentity = try DirectoryIdentity(url: nested)
    let stageIdentity = try DirectoryIdentity(url: staging.directoryURL)

    let lease = try await store.publish(staging)
    defer { lease.close() }
    XCTAssertEqual(synchronization.identities, [
      nestedIdentity, stageIdentity,
      try DirectoryIdentity(url: root.appending(path: "artifacts/model")),
      try DirectoryIdentity(url: root.appending(path: "staging")),
      try DirectoryIdentity(url: root.appending(path: "artifacts")),
      try DirectoryIdentity(url: root),
    ])
    XCTAssertEqual(
      try Data(contentsOf: lease.directoryURL.appending(path: "nested/weight.bin")),
      Data("verified".utf8))
  }

  func testDirectorySynchronizationFailureBeforeRenameNeverPublishes() async throws {
    let root = try temporaryDirectory()
    let synchronization = DirectorySynchronizationProbe(failingCall: 1)
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 0, availableBytes: { _ in UInt64.max },
      synchronizeDirectory: { try synchronization.synchronize($0) })
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "good")])
    let staging = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))

    do {
      _ = try await store.publish(staging)
      XCTFail("failed synchronization cannot produce a publication receipt")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .storageFailure) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL(root, manifest).path))
    do {
      _ = try await store.open(manifest)
      XCTFail("snapshot must be missing before its publication rename")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .missingFile) }
  }

  func testDirectorySynchronizationFailureAfterRenamePreservesVerifiedSnapshot() async throws {
    let root = try temporaryDirectory()
    let synchronization = DirectorySynchronizationProbe(failingCall: 2)
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 0, availableBytes: { _ in UInt64.max },
      synchronizeDirectory: { try synchronization.synchronize($0) })
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "good")])
    let staging = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))

    do {
      _ = try await store.publish(staging)
      XCTFail("failed parent synchronization cannot produce a publication receipt")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .storageFailure) }
    XCTAssertEqual(
      try Data(contentsOf: snapshotURL(root, manifest).appending(path: "weight.bin")),
      Data("good".utf8))
    let reopened = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let lease = try await reopened.open(manifest)
    lease.close()
    try await reopened.remove(manifest)
  }

  func testDeduplicationSynchronizationFailurePreservesExistingSnapshot() async throws {
    let root = try temporaryDirectory()
    let initialStore = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "good")])
    let initialStage = try await initialStore.beginStaging(for: manifest)
    try Data("good".utf8).write(to: initialStage.directoryURL.appending(path: "weight.bin"))
    let initialLease = try await initialStore.publish(initialStage)
    initialLease.close()

    let synchronization = DirectorySynchronizationProbe(failingCall: 1)
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 0, availableBytes: { _ in UInt64.max },
      synchronizeDirectory: { try synchronization.synchronize($0) })
    let replacement = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: replacement.directoryURL.appending(path: "weight.bin"))
    do {
      _ = try await store.publish(replacement)
      XCTFail("failed existing-snapshot synchronization cannot produce a receipt")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .storageFailure) }

    let lease = try await initialStore.open(manifest)
    XCTAssertEqual(
      try Data(contentsOf: lease.directoryURL.appending(path: "weight.bin")), Data("good".utf8))
    lease.close()
  }

  func testDeduplicationCleanupFailurePreservesVerifiedExistingSnapshot() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "good")])
    let initial = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: initial.directoryURL.appending(path: "weight.bin"))
    let initialLease = try await store.publish(initial)
    initialLease.close()

    let replacement = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: replacement.directoryURL.appending(path: "weight.bin"))
    try FileManager.default.createSymbolicLink(
      at: replacement.directoryURL.appending(path: "unexpected-link"),
      withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    do {
      _ = try await store.publish(replacement)
      XCTFail("unsupported quarantine entries must report a cleanup failure")
    } catch let error as ArtifactStoreError { XCTAssertEqual(error, .unsupportedEntry) }

    let lease = try await store.open(manifest)
    XCTAssertEqual(
      try Data(contentsOf: lease.directoryURL.appending(path: "weight.bin")), Data("good".utf8))
    lease.close()
  }

  func testHashMismatchNeverPublishesAndExistingVersionSurvives() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let good = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "good")])
    var staging = try await store.beginStaging(for: good)
    try Data("good".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))
    let goodLease = try await store.publish(staging)
    goodLease.close()

    let bad = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "expected")])
    staging = try await store.beginStaging(for: bad)
    try Data("tampered".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))
    await assertThrowsErrorAsync { _ = try await store.publish(staging) }
    let lease = try await store.open(good)
    lease.close()
  }

  func testSymlinkAndUnexpectedFileAreRejected() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "x")])
    let staging = try await store.beginStaging(for: manifest)
    try FileManager.default.createSymbolicLink(
      at: staging.directoryURL.appending(path: "weight.bin"),
      withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    await assertThrowsErrorAsync { _ = try await store.publish(staging) }
  }

  func testStagingImportUsesNoFollowFileDescriptors() async throws {
    let root = try temporaryDirectory()
    let source = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [entry("nested/weight.bin", "verified")])
    try FileManager.default.createDirectory(
      at: source.appending(path: "nested"), withIntermediateDirectories: false)
    try Data("verified".utf8).write(to: source.appending(path: "nested/weight.bin"))
    var staging = try await store.beginStaging(for: manifest)
    try staging.importFiles(from: source)
    let published = try await store.publish(staging)
    published.close()
    let lease = try await store.open(manifest)
    XCTAssertEqual(
      try Data(contentsOf: lease.directoryURL.appending(path: "nested/weight.bin")),
      Data("verified".utf8))
    lease.close()

    try await store.remove(manifest)
    try FileManager.default.removeItem(at: source.appending(path: "nested/weight.bin"))
    try FileManager.default.createSymbolicLink(
      at: source.appending(path: "nested/weight.bin"),
      withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    staging = try await store.beginStaging(for: manifest)
    XCTAssertThrowsError(try staging.importFiles(from: source))
    staging.abandon()
  }

  func testStagingImportCancellationRemovesPartialFile() async throws {
    let root = try temporaryDirectory()
    let source = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let byteCount: UInt64 = 256 * 1_024 * 1_024
    let manifest = try ArtifactManifest(
      artifactID: "large",
      files: [
        try ArtifactEntry(path: "large.bin", byteCount: byteCount, sha256: digest("unused"))
      ])
    let sourceFile = source.appending(path: "large.bin")
    FileManager.default.createFile(atPath: sourceFile.path, contents: Data())
    let handle = try FileHandle(forWritingTo: sourceFile)
    try handle.truncate(atOffset: byteCount)
    try handle.close()
    let staging = try await store.beginStaging(for: manifest)
    let partial = staging.directoryURL.appending(path: "large.bin")
    let task = Task { try staging.importFiles(from: source) }
    for _ in 0..<1_000 {
      if FileManager.default.fileExists(atPath: partial.path) { break }
      try await Task.sleep(for: .microseconds(100))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    task.cancel()
    do {
      try await task.value
      XCTFail("cancelled import must not succeed")
    } catch is CancellationError {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    staging.abandon()
  }

  func testStagingImportRejectsFIFOWithoutWaitingForAWriter() async throws {
    let root = try temporaryDirectory()
    let source = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [entry("weight.bin", "x")])
    let fifo = source.appending(path: "weight.bin")
    XCTAssertEqual(fifo.path.withCString { mkfifo($0, S_IRUSR | S_IWUSR) }, 0)
    let staging = try await store.beginStaging(for: manifest)
    let completed = DispatchSemaphore(value: 0)
    let task = Task.detached {
      let result = Result { try staging.importFiles(from: source) }
      completed.signal()
      return result
    }
    let rejectedPromptly = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: completed.wait(timeout: .now() + 1) == .success)
      }
    }
    XCTAssertTrue(rejectedPromptly, "unsupported FIFO input must not block the import thread")

    // Release a regressed blocking open so the test can fail without leaving a worker behind.
    let rescue = rejectedPromptly ? -1 : fifo.path.withCString { open($0, O_RDWR | O_NONBLOCK) }
    defer {
      if rescue >= 0 { nativeAgentClose(rescue) }
      staging.abandon()
    }
    switch await task.value {
    case .success:
      XCTFail("FIFO input must be rejected")
    case .failure(let error):
      XCTAssertEqual(error as? ArtifactStoreError, .sizeMismatch)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: staging.directoryURL.appending(path: "weight.bin").path))
  }

  func testArtifactParentSymlinkCannotEscapeRoot() async throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "x")])
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "artifacts/model"), withDestinationURL: outside)
    let staging = try await store.beginStaging(for: manifest)
    try Data("x".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))
    await assertThrowsErrorAsync { _ = try await store.publish(staging) }
    await assertThrowsErrorAsync { _ = try await store.open(manifest) }
    await assertThrowsErrorAsync { try await store.remove(manifest) }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
  }

  func testCorruptDestinationIsRecoveredByVerifiedRestage() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [entry("weight.bin", "good")])
    let corrupt = root.appending(path: "artifacts/model/\(manifest.manifestDigest.rawValue)")
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    try Data("bad".utf8).write(to: corrupt.appending(path: "weight.bin"))
    let staging = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))
    let published = try await store.publish(staging)
    published.close()
    let lease = try await store.open(manifest)
    lease.close()
  }

  func testRepeatedCorruptOpenDoesNotLeakSnapshotDescriptors() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [entry("weight.bin", "good")])
    let corrupt = root.appending(path: "artifacts/model/\(manifest.manifestDigest.rawValue)")
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    try Data("bad".utf8).write(to: corrupt.appending(path: "weight.bin"))

    let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    for _ in 0..<256 {
      await assertThrowsErrorAsync { _ = try await store.open(manifest) }
    }
    let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    XCTAssertLessThanOrEqual(after, before + 2)

    let staging = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))
    let published = try await store.publish(staging)
    published.close()
    let lease = try await store.open(manifest)
    lease.close()
  }

  func testCancelledDeduplicatedPublishNeverDeletesValidSnapshot() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let bytes = Data(repeating: 0x61, count: 8 * 1_024 * 1_024)
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [try entry("weight.bin", bytes)])
    var staging = try await store.beginStaging(for: manifest)
    try bytes.write(to: staging.directoryURL.appending(path: "weight.bin"))
    let initialLease = try await store.publish(staging)
    initialLease.close()

    staging = try await store.beginStaging(for: manifest)
    try bytes.write(to: staging.directoryURL.appending(path: "weight.bin"))
    let task = Task {
      let lease = try await store.publish(staging)
      lease.close()
    }
    try await Task.sleep(for: .milliseconds(1))
    task.cancel()
    _ = try? await task.value

    let lease = try await store.open(manifest)
    lease.close()
  }

  func testCancelledLockWaitDoesNotConsumeOrPublishStaging() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let manifest = try ArtifactManifest(
      artifactID: "model", files: [entry("weight.bin", "good")])
    let staging = try await store.beginStaging(for: manifest)
    try Data("good".utf8).write(to: staging.directoryURL.appending(path: "weight.bin"))
    let locks = try nativeAgentOpenDirectory(path: root.appending(path: "locks").path)
    let blocker = try ArtifactFileLock(
      directory: locks, name: "staging.lock", exclusive: true, nonblocking: true)
    let task = Task {
      let lease = try await store.publish(staging)
      lease.close()
    }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    blocker.close()
    nativeAgentClose(locks)
    do {
      try await task.value
      XCTFail("cancelled publish must not commit")
    } catch is CancellationError {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: staging.directoryURL.path))
    staging.abandon()
  }

  #if os(macOS)
    func testFlockExcludesAnotherProcessAndCrashReleasesLease() async throws {
      let root = try temporaryDirectory()
      let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
      let manifest = try ArtifactManifest(
        artifactID: "text", files: [entry("model.bin", "model")])
      let staging = try await store.beginStaging(for: manifest)
      try Data("model".utf8).write(to: staging.directoryURL.appending(path: "model.bin"))
      let lease = try await store.publish(staging)
      lease.close()

      let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appending(path: "ModelArtifactStoreTestHelper")
      let ready = root.appending(path: "child-ready")
      let process = Process()
      process.executableURL = helper
      process.arguments = [root.path, ready.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      defer {
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
      let deadline = Date().addingTimeInterval(3)
      while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
      do {
        try await store.remove(manifest)
        XCTFail("child lease must block")
      } catch let error as ArtifactStoreError { XCTAssertEqual(error, .busy) }
      process.terminate()
      process.waitUntilExit()
      try await store.remove(manifest)
    }
  #endif

  func testLowDiskAndLiveStagingRecoveryAreExplicit() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(
      rootURL: root, minimumFreeBytes: 10, availableBytes: { _ in 10 })
    let manifest = try ArtifactManifest(artifactID: "model", files: [entry("weight.bin", "x")])
    await assertThrowsErrorAsync { _ = try await store.beginStaging(for: manifest) }

    let recoverable = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    var staging: ArtifactStaging? = try await recoverable.beginStaging(for: manifest)
    let directory = try XCTUnwrap(staging?.directoryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: directory.path)
    let activeRemoved = try await recoverable.recoverStaging(olderThan: .seconds(1))
    XCTAssertEqual(activeRemoved, 0)
    staging?.abandon()
    staging = nil
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: directory.path)
    let observedDate = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date)
    XCTAssertLessThan(observedDate, Date().addingTimeInterval(-1))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: directory.path)
    let staleRemoved = try await recoverable.recoverStaging(olderThan: .seconds(1))
    XCTAssertEqual(staleRemoved, 1)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "native-agent-artifact-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func snapshotURL(_ root: URL, _ manifest: ArtifactManifest) -> URL {
    root.appending(path: "artifacts/\(manifest.artifactID)/\(manifest.manifestDigest.rawValue)")
  }

  private func entry(_ path: String, _ value: String) throws -> ArtifactEntry {
    try ArtifactEntry(path: path, byteCount: UInt64(value.utf8.count), sha256: digest(value))
  }

  private func entry(_ path: String, _ value: Data) throws -> ArtifactEntry {
    let digest = ArtifactDigest(
      rawValue: SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined())!
    return try ArtifactEntry(path: path, byteCount: UInt64(value.count), sha256: digest)
  }

  private func digest(_ value: String) -> ArtifactDigest {
    ArtifactDigest(
      rawValue: SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined())!
  }
}

extension XCTestCase {
  fileprivate func assertThrowsErrorAsync(
    _ operation: @escaping () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("expected error", file: file, line: line)
    } catch {}
  }
}

private final class VerificationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }



}

private struct DirectoryIdentity: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t

  init(descriptor: Int32) throws {
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else { throw ArtifactStoreError.storageFailure }
    device = information.st_dev
    inode = information.st_ino
  }

  init(url: URL) throws {
    let descriptor = try nativeAgentOpenDirectory(path: url.path)
    defer { nativeAgentClose(descriptor) }
    try self.init(descriptor: descriptor)
  }
}

private final class DirectorySynchronizationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let failingCall: Int?
  private var synchronizedDirectories: [DirectoryIdentity] = []

  init(failingCall: Int? = nil) { self.failingCall = failingCall }

  var identities: [DirectoryIdentity] {
    lock.lock()
    defer { lock.unlock() }
    return synchronizedDirectories
  }

  func synchronize(_ descriptor: Int32) throws {
    let identity = try DirectoryIdentity(descriptor: descriptor)
    lock.lock()
    synchronizedDirectories.append(identity)
    let shouldFail = synchronizedDirectories.count == failingCall
    lock.unlock()
    if shouldFail { throw ArtifactStoreError.storageFailure }
    try nativeAgentSynchronize(descriptor)
  }
}
