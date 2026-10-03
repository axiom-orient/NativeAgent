import Foundation
import NativeAgent
import ModelArtifactStore
import MLXProvider

/// A bounded receipt emitted by the app-hosted physical-device smoke test.
///
/// The source identity is supplied by the qualification command. The host does
/// not infer an archive digest from its own build products.
public struct NativeAgentMLXDeviceQualificationReceipt: Codable, Equatable, Sendable {
  public let sourceIdentity: String
  public let modelRepositoryID: String
  public let modelRevision: String
  public let sessionID: String
  public let outputByteCount: Int
  public let requiredTokenObserved: Bool
  public let restoredMessageCount: Int
  public let firstStatus: String
  public let cancellationDrainObserved: Bool
  public let cleanupObserved: Bool

  public init(
    sourceIdentity: String,
    modelRepositoryID: String,
    modelRevision: String,
    sessionID: String,
    outputByteCount: Int,
    requiredTokenObserved: Bool,
    restoredMessageCount: Int,
    firstStatus: String,
    cancellationDrainObserved: Bool,
    cleanupObserved: Bool
  ) {
    self.sourceIdentity = sourceIdentity
    self.modelRepositoryID = modelRepositoryID
    self.modelRevision = modelRevision
    self.sessionID = sessionID
    self.outputByteCount = outputByteCount
    self.requiredTokenObserved = requiredTokenObserved
    self.restoredMessageCount = restoredMessageCount
    self.firstStatus = firstStatus
    self.cancellationDrainObserved = cancellationDrainObserved
    self.cleanupObserved = cleanupObserved
  }
}

public enum NativeAgentMLXDeviceQualificationRunner {
  public static let appName = "NativeAgentMLXDeviceQualification"
  public static let modelRepositoryID = "mlx-community/Qwen3.5-0.8B-MLX-4bit"
  public static let modelRevision = "5d894f8cc4ef3e6c88537bf3746ed262f549da6a"
  public static let requiredToken = "DEVICE_OK"
  public static let prompt =
    "Reply with one short sentence containing the token \(requiredToken). Do not use tools."

  /// Runs the real MLX → ModelRuntime → NativeAgent path and reloads the
  /// resulting durable session through a newly composed runtime and Agent.
  ///
  /// This method intentionally has no fixture or mock branch. It is expected
  /// to run only from an app-hosted XCTest on a physical iOS device.
  public static func run() async throws -> NativeAgentMLXDeviceQualificationReceipt {
    let sourceIdentity = try sourceIdentityFromEnvironment()
    let model = try MLXModel(
      repositoryID: modelRepositoryID,
      revision: modelRevision,
      extraEOSTokens: ["<|im_end|>"],
      disablesThinking: true,
      sampling: .init(temperature: 0, topP: 1, topK: 0, repetitionPenalty: 1)
    )

    let root = try qualificationRoot()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let specificationsURL = root.appendingPathComponent(
      "resolved-specifications.json", isDirectory: false)
    let store = try ModelArtifactStore(rootURL: root)
    var runtimes: [MLXTextRuntime] = []
    var cleanupActions: [(name: String, action: () async throws -> Void)] = []

    print(
      "NATIVE_AGENT_MLX_DEVICE_START source=\(sourceIdentity) "
        + "model=\(modelRepositoryID) revision=\(modelRevision)"
    )

    do {
      let runtime = MLXTextRuntime(
        store: store,
        specificationsPersistenceURL: specificationsURL
      )
      runtimes.append(runtime)
      let prepared = try await runtime.prepare(model) { progress in
        guard progress.currentFile == nil else { return }
        print(
          "NATIVE_AGENT_MLX_DEVICE_DOWNLOAD model=\(modelRepositoryID) "
            + "bytes=\(progress.completedBytes)/\(progress.totalBytes)"
        )
      }
      let modelRuntime = try await runtime.loadRuntime(
        prepared
      )
      cleanupActions.append(("first model runtime", { try await modelRuntime.shutdown() }))
      cleanupActions.append(("first MLX runtime", { try await runtime.unload() }))

      let agent = try Agent(
        modelRuntime: modelRuntime,
        appName: appName,
        instructions: "Answer briefly and keep the requested token unchanged."
      )
      let sessionID = "mlx-device-\(UUID().uuidString.lowercased())"
      let firstRun = try await agent.run(
        prompt,
        sessionID: sessionID,
        title: "MLX physical-device qualification"
      )
      let output = try requireNonEmptyOutput(firstRun.output)
      guard output.contains(requiredToken) else {
        throw QualificationFailure(
          "NativeAgent output did not preserve the required token \(requiredToken)."
        )
      }
      guard firstRun.status == .completed else {
        throw QualificationFailure(
          "NativeAgent run ended with status \(firstRun.status.rawValue)."
        )
      }
      let firstSnapshot = try await agent.session(id: sessionID)
      guard firstSnapshot.messages.contains(where: { message in
        message.role == .assistant && message.content == output
      }) else {
        throw QualificationFailure(
          "The first Agent run returned output that was not durably persisted."
        )
      }

      try await modelRuntime.shutdown()
      let firstCleanupObserved = (await modelRuntime.status()).phase == .closed
      // `ModelRuntime` is a borrowed wrapper. Closing it drains the run boundary but
      // does not release the host-owned MLX resident or its process residency lease.
      // The qualification intentionally opens a second resident, so the owner must
      // unload the first resident before attempting that load.
      try await runtime.unload()

      let restartedRuntime = MLXTextRuntime(
        store: store,
        specificationsPersistenceURL: specificationsURL
      )
      runtimes.append(restartedRuntime)
      cleanupActions.append(("restored MLX runtime", { try await restartedRuntime.unload() }))
      let restoredPrepared = try await restartedRuntime.prepare(model)
      let restoredModelRuntime = try await restartedRuntime.loadRuntime(
        restoredPrepared
      )
      cleanupActions.append(("restored model runtime", { try await restoredModelRuntime.shutdown() }))
      let streamProbe = QualificationStreamProbe()
      let restartedAgent = try Agent(
        modelRuntime: restoredModelRuntime,
        appName: appName,
        instructions: "Answer briefly and keep the requested token unchanged.",
        observer: streamProbe
      )
      let restoredSnapshot = try await restartedAgent.session(id: sessionID)
      guard restoredSnapshot == firstSnapshot else {
        throw QualificationFailure(
          "Reloaded Agent session differs from the durably persisted first snapshot."
        )
      }

      let continuation = try await restartedAgent.send(prompt, to: sessionID)
      guard continuation.status == .completed,
            continuation.output?.contains(requiredToken) == true else {
        throw QualificationFailure("Restored session failed to continue generation.")
      }

      let cancellationSessionID = "mlx-device-cancel-\(UUID().uuidString.lowercased())"
      let cancellationTask = Task {
        try await restartedAgent.run(
          "Write a detailed response of at least 1,000 words about deterministic software testing.",
          sessionID: cancellationSessionID,
          title: "MLX physical-device cancellation qualification"
        )
      }
      var cancellationStarted = false
      for _ in 0..<3_000 {
        if await streamProbe.sawText(sessionID: cancellationSessionID) {
          cancellationStarted = true
          break
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard cancellationStarted else {
        cancellationTask.cancel()
        _ = try? await cancellationTask.value
        throw QualificationFailure(
          "The cancellation probe did not observe a native text delta."
        )
      }

      await restoredModelRuntime.cancelActiveRun()
      do {
        _ = try await cancellationTask.value
        throw QualificationFailure(
          "The MLX generation completed instead of reporting cancellation."
        )
      } catch is CancellationError {
        // Expected only after ModelRuntime has drained the provider pump.
      }
      guard (await restoredModelRuntime.status()).phase == .idle else {
        throw QualificationFailure(
          "ModelRuntime did not return to idle after cancellation drain."
        )
      }
      let cancelledSnapshot = try await restartedAgent.session(id: cancellationSessionID)
      guard cancelledSnapshot.status == .failed,
            cancelledSnapshot.waitState == nil,
            cancelledSnapshot.messages.allSatisfy({ $0.role != .assistant }) else {
        throw QualificationFailure(
          "Cancelled generation did not persist the expected failed, non-waiting session."
        )
      }
      let cancellationDrainObserved = true

      try await restoredModelRuntime.shutdown()
      let restoredCleanupObserved = (await restoredModelRuntime.status()).phase == .closed
      for runtime in runtimes {
        try await runtime.unload()
      }
      let cleanupObserved = firstCleanupObserved && restoredCleanupObserved
      guard cleanupObserved else {
        throw QualificationFailure("Model runtime cleanup was not observed as closed.")
      }

      let receipt = NativeAgentMLXDeviceQualificationReceipt(
        sourceIdentity: sourceIdentity,
        modelRepositoryID: modelRepositoryID,
        modelRevision: modelRevision,
        sessionID: sessionID,
        outputByteCount: output.utf8.count,
        requiredTokenObserved: true,
        restoredMessageCount: restoredSnapshot.messages.count,
        firstStatus: firstRun.status.rawValue,
        cancellationDrainObserved: cancellationDrainObserved,
        cleanupObserved: cleanupObserved
      )
      print(
        "NATIVE_AGENT_MLX_DEVICE_PASS source=\(sourceIdentity) "
          + "model=\(modelRepositoryID) revision=\(modelRevision) "
          + "session=\(sessionID) outputBytes=\(receipt.outputByteCount) "
          + "restoredMessages=\(receipt.restoredMessageCount) "
          + "cancellationDrain=observed cleanup=closed"
      )
      return receipt
    } catch {
      print(
        "NATIVE_AGENT_MLX_DEVICE_FAILURE source=\(sourceIdentity) "
          + "model=\(modelRepositoryID) revision=\(modelRevision) "
          + "error=\(boundedDescription(error))"
      )
      let cleanupFailures = await cleanup(actions: cleanupActions)
      if cleanupFailures.isEmpty == false {
        let details = cleanupFailures.joined(separator: "; ")
        print("NATIVE_AGENT_MLX_DEVICE_CLEANUP_FAILURE details=\(details)")
        throw QualificationFailure(
          "Qualification failed and cleanup was incomplete: \(details). Primary error: \(boundedDescription(error))"
        )
      }
      throw error
    }
  }

  // One owner for every qualification entrypoint. The pre-clean-break cache
  // remains untouched; its AMA manifest identities are not NativeAgent data.
  static func qualificationRoot() throws -> URL {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first else {
      throw QualificationFailure("Application Support is unavailable on this device.")
    }
    return applicationSupport
      .appendingPathComponent(appName, isDirectory: true)
      .appendingPathComponent("NativeAgent", isDirectory: true)
      .appendingPathComponent("MLX", isDirectory: true)
  }

  private static func sourceIdentityFromEnvironment() throws -> String {
    let value = ProcessInfo.processInfo.environment["NATIVE_AGENT_SOURCE_SHA256"] ?? ""
    guard value.utf8.count == 64,
          value.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57)
              || (byte >= 65 && byte <= 70)
              || (byte >= 97 && byte <= 102)
          }) else {
      throw QualificationFailure(
        "NATIVE_AGENT_SOURCE_SHA256 must be a 64-character SHA-256 digest supplied by the qualification command."
      )
    }
    return value.lowercased()
  }

  private static func requireNonEmptyOutput(_ output: String?) throws -> String {
    let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard trimmed.isEmpty == false else {
      throw QualificationFailure("NativeAgent returned empty assistant output.")
    }
    return trimmed
  }

  private static func cleanup(
    actions: [(name: String, action: () async throws -> Void)]
  ) async -> [String] {
    var failures: [String] = []
    for item in actions.reversed() {
      do {
        try await item.action()
      } catch {
        failures.append("\(item.name): \(boundedDescription(error))")
      }
    }
    return failures
  }

  private static func boundedDescription(_ error: any Error) -> String {
    let value = String(describing: error)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return String(value.prefix(2_048))
  }
}

private struct QualificationFailure: Error, LocalizedError, Sendable {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

private actor QualificationStreamProbe: RuntimeObserver {
  private var sessionsWithText: Set<String> = []

  func record(modelStream event: ModelInvocationStreamEvent) async {
    if case .textDelta(let text) = event.event, !text.isEmpty {
      sessionsWithText.insert(event.sessionID)
    }
  }

  func record(effectDecision event: ToolEffectDecisionEvent) async {}
  func record(toolExecutionDuration event: ToolExecutionDurationEvent) async {}
  func sawText(sessionID: String) -> Bool { sessionsWithText.contains(sessionID) }
}
