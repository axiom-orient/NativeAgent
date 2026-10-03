import ModelArtifactStore
import Foundation
import LanguageModelCore
import LanguageModelRuntime

protocol LeapProcessResidencyLease: AnyObject, Sendable {
  func close()
  func poison(retaining objects: [AnyObject])
}

protocol LeapProcessResidency: Sendable {
  func isPoisoned() -> Bool
  func claim(_ candidate: UUID) throws -> any LeapProcessResidencyLease
}

extension ProcessResidencyLease: LeapProcessResidencyLease {}

private struct LeapLiveProcessResidency: LeapProcessResidency {
  let base: ProcessResidency

  func isPoisoned() -> Bool { base.isPoisoned() }

  func claim(_ candidate: UUID) throws -> any LeapProcessResidencyLease {
    try base.claim(candidate)
  }
}

private final class LeapLifecycleCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
  }
}

private typealias LeapGenerationHandle = LeapResultHandle<Void>
private typealias LeapLoadHandle = LeapResultHandle<any LeapVoiceSession>
private typealias LeapTextLoadHandle = LeapResultHandle<any LeapTextSession>

// Scheduling policy for observing native completion. Generation deadlines remain
// owned by LeapWatchdog; these intervals never change an operation's outcome.
private enum LeapRuntimeScheduling {
  static let lifecyclePoll: Duration = .milliseconds(5)
  static let loadResultPoll: Duration = .milliseconds(10)
  static let watchdogPoll: Duration = .milliseconds(20)
  static let voiceShutdownRetryDelay: Duration = .milliseconds(300)
}

struct LeapWatchdog: Sendable {
  let total: Duration
  let inactivity: Duration

  static let live = Self(total: .seconds(180), inactivity: .seconds(30))

  init(total: Duration, inactivity: Duration) {
    precondition(total > .zero && inactivity > .zero)
    self.total = total
    self.inactivity = inactivity
  }

  fileprivate var totalNanoseconds: UInt64 { Self.nanoseconds(total) }
  fileprivate var inactivityNanoseconds: UInt64 { Self.nanoseconds(inactivity) }

  private static func nanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = UInt64(max(0, components.seconds))
    let attoseconds = UInt64(max(0, components.attoseconds))
    return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
  }
}

private final class LeapGenerationState: @unchecked Sendable {
  private enum Phase { case running, terminal }
  private let lock = NSLock()
  private var phase: Phase = .running
  private var invalid = false
  private var failure: LeapError?
  private var eventCount = 0
  private var lastActivity = DispatchTime.now().uptimeNanoseconds

  @discardableResult
  func observe(_ event: LeapVoiceEvent) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    eventCount += 1
    guard failure == nil else { return false }
    guard eventCount <= LeapLimits.maxResponseEvents else {
      failure = .outputLimitExceeded
      return false
    }
    switch event {
    case .completed:
      guard phase == .running else {
        invalid = true
        return false
      }
      phase = .terminal
      lastActivity = DispatchTime.now().uptimeNanoseconds
      return true
    case .transcriptDelta, .textDelta, .pcm:
      if phase == .terminal {
        invalid = true
        return false
      }
      let hasPayload: Bool
      switch event {
      case .transcriptDelta(let value), .textDelta(let value): hasPayload = !value.isEmpty
      case .pcm(let samples, _): hasPayload = !samples.isEmpty
      case .completed: hasPayload = true
      }
      if hasPayload { lastActivity = DispatchTime.now().uptimeNanoseconds }
      return hasPayload
    }
  }

  func inactivityNanoseconds() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return DispatchTime.now().uptimeNanoseconds &- lastActivity
  }

  func hasValidTerminal() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return phase == .terminal && !invalid && failure == nil
  }

  func failureValue() -> LeapError? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }
}

private final class LeapTextGenerationState: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""
  private var chunkCount = 0
  private var failure: LeapError?
  private var terminal = false
  private var lastActivity = DispatchTime.now().uptimeNanoseconds

  func observe(_ chunk: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard failure == nil, !terminal else {
      failure = .invalidRuntimeOutput
      return nil
    }
    chunkCount += 1
    guard chunkCount <= LeapLimits.maxTextChunks else {
      failure = .outputLimitExceeded
      return nil
    }
    guard text.utf8.count + chunk.utf8.count <= LeapLimits.maxTextGenerationBytes else {
      failure = .outputLimitExceeded
      return nil
    }
    if !chunk.isEmpty {
      text += chunk
      lastActivity = DispatchTime.now().uptimeNanoseconds
      return chunk
    }
    return nil
  }

  func failureValue() -> LeapError? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }

  func observeCompletion() {
    lock.lock()
    defer { lock.unlock() }
    guard failure == nil, !terminal else {
      failure = .invalidRuntimeOutput
      return
    }
    terminal = true
  }

  func hasValidTerminal() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminal && failure == nil
  }

  func accumulatedText() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return failure == nil ? text : nil
  }

  func inactivityNanoseconds() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return DispatchTime.now().uptimeNanoseconds &- lastActivity
  }
}

private final class LeapTextRunnerBox: @unchecked Sendable {
  let session: any LeapTextSession
  init(_ session: any LeapTextSession) { self.session = session }
}

// Cleanup must outlive the invocation's cancellation. Await the owned task so
// leases cannot be released, or another resident loaded, before native teardown.
private func shutdownTextSession(_ session: any LeapTextSession) async throws {
  try await Task.detached { try await session.shutdown() }.value
}

private func shutdownVoiceSession(_ session: any LeapVoiceSession) async throws {
  try await Task.detached {
    do {
      try await session.shutdown()
    } catch {
      try await Task.sleep(for: LeapRuntimeScheduling.voiceShutdownRetryDelay)
      try await session.shutdown()
    }
  }.value
}

public struct LeapVoiceGenerator: Sendable {
  private let runtime: LeapRuntime
  private let model: LeapVoiceModel

  fileprivate init(runtime: LeapRuntime, model: LeapVoiceModel) {
    self.runtime = runtime
    self.model = model
  }

  public func events(for request: LeapVoiceRequest) -> AsyncThrowingStream<
    LeapVoiceEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await runtime.generate(for: model, request: request) {
            continuation.yield($0)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

public actor LeapRuntime {
  private struct VoiceResident {
    let model: LeapVoiceModel
    let artifactLease: ArtifactLease
    let processLease: any LeapProcessResidencyLease
    let session: any LeapVoiceSession
  }

  private struct TextResident {
    let model: LeapTextModel
    let artifactLease: ArtifactLease
    let processLease: any LeapProcessResidencyLease
    let session: any LeapTextSession
    let modelURL: URL
  }

  private struct VoiceLoad {
    let token: UUID
    let model: LeapVoiceModel
    let handle: LeapLoadHandle
    let task: Task<Void, Never>
    let artifactLease: ArtifactLease
    let processLease: any LeapProcessResidencyLease
  }

  private struct TextLoad {
    let token: UUID
    let model: LeapTextModel
    let handle: LeapTextLoadHandle
    let task: Task<Void, Never>
    let artifactLease: ArtifactLease
    let processLease: any LeapProcessResidencyLease
    let modelURL: URL
  }

  private enum Drain {
    case voiceGeneration(
      handle: LeapGenerationHandle, task: Task<Void, Never>, resident: VoiceResident)
    case textGeneration(
      handle: LeapGenerationHandle, task: Task<Void, Never>, resident: TextResident)
    case voiceLoad(VoiceLoad)
    case textLoad(TextLoad)
  }

  /// Exactly one of voice, text, loading, or draining can own native weights.
  /// Loading tokens are written before native awaits and checked before commit.
  private enum ResidencyState {
    case empty
    case loadingVoice(VoiceLoad)
    case loadingText(TextLoad)
    case voice(VoiceResident)
    case text(TextResident)
    case draining(Drain)
    case poisoned
  }

  private let store: ModelArtifactStore
  private let downloader: any LeapDownloading
  private let loader: LeapVoiceSessionLoader
  private let textLoader: LeapTextSessionLoader
  private let residency: any LeapProcessResidency
  private let watchdog: LeapWatchdog
  private let beforeLoadCommit: (@Sendable () async -> Void)?
  private let artifactOpenObserver: (@Sendable () -> Void)?
  private let beforeArtifactOpen: (@Sendable () async -> Void)?
  private let beforeReapDrain: (@Sendable () async -> Void)?
  private let residencyID = UUID()
  private var state: ResidencyState = .empty
  private var operationActive = false
  private var lifecycleCancellation: LeapLifecycleCancellation?
  private var activeNativeTask: Task<Void, Never>?
  private var verifiedArtifacts: [ArtifactManifest: ArtifactLease] = [:]
  private var verifiedArtifactOrder: [ArtifactManifest] = []

  private static let verifiedArtifactCacheLimit = 4

  public init(store: ModelArtifactStore) {
    self.store = store
    downloader = LeapHTTPDownloader()
    loader = .live
    textLoader = .live
    residency = LeapLiveProcessResidency(base: .shared)
    watchdog = .live
    beforeLoadCommit = nil
    artifactOpenObserver = nil
    beforeArtifactOpen = nil
    beforeReapDrain = nil
  }

  init(
    store: ModelArtifactStore,
    downloader: any LeapDownloading,
    loader: LeapVoiceSessionLoader,
    residency: ProcessResidency = .shared,
    watchdog: LeapWatchdog = .live,
    textLoader: LeapTextSessionLoader = .live,
    beforeLoadCommit: (@Sendable () async -> Void)? = nil,
    artifactOpenObserver: (@Sendable () -> Void)? = nil,
    beforeArtifactOpen: (@Sendable () async -> Void)? = nil,
    beforeReapDrain: (@Sendable () async -> Void)? = nil
  ) {
    self.store = store
    self.downloader = downloader
    self.loader = loader
    self.textLoader = textLoader
    self.residency = LeapLiveProcessResidency(base: residency)
    self.watchdog = watchdog
    self.beforeLoadCommit = beforeLoadCommit
    self.artifactOpenObserver = artifactOpenObserver
    self.beforeArtifactOpen = beforeArtifactOpen
    self.beforeReapDrain = beforeReapDrain
  }

  init(
    store: ModelArtifactStore,
    downloader: any LeapDownloading,
    loader: LeapVoiceSessionLoader,
    residency: any LeapProcessResidency,
    watchdog: LeapWatchdog = .live,
    textLoader: LeapTextSessionLoader = .live,
    beforeLoadCommit: (@Sendable () async -> Void)? = nil,
    artifactOpenObserver: (@Sendable () -> Void)? = nil,
    beforeArtifactOpen: (@Sendable () async -> Void)? = nil,
    beforeReapDrain: (@Sendable () async -> Void)? = nil
  ) {
    self.store = store
    self.downloader = downloader
    self.loader = loader
    self.textLoader = textLoader
    self.residency = residency
    self.watchdog = watchdog
    self.beforeLoadCommit = beforeLoadCommit
    self.artifactOpenObserver = artifactOpenObserver
    self.beforeArtifactOpen = beforeArtifactOpen
    self.beforeReapDrain = beforeReapDrain
  }

  public nonisolated func generator(for model: LeapVoiceModel) -> LeapVoiceGenerator {
    .init(runtime: self, model: model)
  }

  nonisolated func modelClient(for model: LeapTextModel) -> LeapModelClient {
    LeapModelClient(runtime: self, model: model)
  }

  public func readiness(for model: LeapTextModel) async throws -> LeapReadiness {
    try await readiness(
      manifest: model.manifest,
      resident: { [self] in
        guard case .text(let resident) = state else { return false }
        return resident.model.identity == model.identity
      },
      loading: { [self] in
        guard case .loadingText(let loading) = state else { return false }
        return loading.model.identity == model.identity
      })
  }

  public func readiness(for model: LeapVoiceModel) async throws -> LeapReadiness {
    try await readiness(
      manifest: model.manifest,
      resident: { [self] in
        guard case .voice(let resident) = state else { return false }
        return resident.model.identity == model.identity
      },
      loading: { [self] in
        guard case .loadingVoice(let loading) = state else { return false }
        return loading.model.identity == model.identity
      })
  }

  private func readiness(
    manifest: ArtifactManifest,
    resident: () -> Bool,
    loading: () -> Bool
  ) async throws -> LeapReadiness {
    try ensureHealthy()
    if operationActive { return .busy }
    do {
      try await reapDrain()
    } catch LeapError.busy {
      return .busy
    }
    try Task.checkCancellation()
    try ensureHealthy()
    if resident() { return .ready }
    if loading() { return .busy }
    if verifiedArtifacts[manifest] != nil {
      try Task.checkCancellation()
      return .ready
    }
    do {
      let lease = try await openVerifiedArtifact(manifest)
      do {
        try Task.checkCancellation()
      } catch {
        lease.close()
        throw error
      }
      cacheVerifiedArtifact(lease)
      return .ready
    } catch ArtifactStoreError.missingFile {
      try Task.checkCancellation()
      return .missing
    } catch {
      try Task.checkCancellation()
      throw Self.normalizeArtifact(error)
    }
  }

  @discardableResult
  public func prepare(
    _ model: LeapTextModel = .default,
    progress: (@Sendable (LeapDownloadProgress) -> Void)? = nil
  ) async throws -> LeapPreparedTextModel {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain()
    try Task.checkCancellation()
    try await prepareArtifact(
      repositoryID: model.repositoryID, revision: model.revision, manifest: model.manifest,
      progress: progress)
    return LeapPreparedTextModel(model: model)
  }

  public func prepare(
    _ model: LeapVoiceModel,
    progress: (@Sendable (LeapDownloadProgress) -> Void)? = nil
  ) async throws {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain()
    try Task.checkCancellation()
    try await prepareArtifact(
      repositoryID: model.repositoryID, revision: model.revision, manifest: model.manifest,
      progress: progress)
  }

  @discardableResult
  public func importModel(
    _ model: LeapTextModel = .default, from directoryURL: URL
  ) async throws -> LeapPreparedTextModel {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain()
    try Task.checkCancellation()
    try await importArtifact(model.manifest, from: directoryURL)
    return LeapPreparedTextModel(model: model)
  }

  public func importModel(_ model: LeapVoiceModel, from directoryURL: URL) async throws {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain()
    try Task.checkCancellation()
    try await importArtifact(model.manifest, from: directoryURL)
  }

  public func load(_ prepared: LeapPreparedTextModel) async throws {
    try await load(prepared.model)
  }

  func load(_ model: LeapTextModel) async throws {
    try ensureHealthy()
    if case .text(let resident) = state, !operationActive,
      resident.model.identity == model.identity
    {
      return
    }
    if case .loadingText(let loading) = state, loading.model.identity == model.identity {
      do {
        _ = try await waitForTextLoad(loading, cancellation: nil, owner: false)
        try await waitForTextLoadCommit(loading)
      } catch {
        throw Self.normalizeLoad(error)
      }
      return
    }
    try beginOperation()
    let cancellation = LeapLifecycleCancellation()
    lifecycleCancellation = cancellation
    defer {
      lifecycleCancellation = nil
      activeNativeTask = nil
      operationActive = false
    }
    try await reapDrain()
    try checkLifecycleCancellation(cancellation)
    try ensureHealthy()
    if case .text(let resident) = state, resident.model.identity == model.identity {
      return
    }
    switch state {
    case .voice, .text:
      try await unloadResident()
    case .empty:
      break
    case .loadingVoice, .loadingText:
      throw LeapError.busy
    case .draining, .poisoned:
      throw LeapError.busy
    }

    try checkLifecycleCancellation(cancellation)
    let artifactLease = try await takeOrOpenArtifact(model.manifest)
    do {
      try checkLifecycleCancellation(cancellation)
    } catch {
      artifactLease.close()
      throw error
    }
    let processLease: any LeapProcessResidencyLease
    do {
      processLease = try claimResidency()
    } catch {
      artifactLease.close()
      throw error
    }
    do {
      try checkLifecycleCancellation(cancellation)
    } catch {
      artifactLease.close()
      processLease.close()
      throw error
    }
    let modelURL = artifactLease.directoryURL.appending(path: model.modelPath)
    let load = makeTextLoad(
      token: UUID(), model: model, artifactLease: artifactLease, processLease: processLease,
      modelURL: modelURL)
    state = .loadingText(load)
    activeNativeTask = load.task
    do {
      let session = try await waitForTextLoad(load, cancellation: cancellation, owner: true)
      if let beforeLoadCommit { await beforeLoadCommit() }
      do {
        try checkLifecycleCancellation(cancellation)
      } catch let cancellationError {
        do {
          try await cleanupTextLoadSession(
            session, artifactLease: artifactLease, processLease: processLease, token: load.token)
        } catch {
          throw error
        }
        throw cancellationError
      }
      guard case .loadingText(let current) = state, current.token == load.token else {
        try await cleanupTextLoadSession(
          session, artifactLease: artifactLease, processLease: processLease, token: load.token)
        throw LeapError.busy
      }
      state = .text(
        TextResident(
          model: model, artifactLease: artifactLease, processLease: processLease,
          session: session, modelURL: modelURL))
    } catch {
      if case .loadingText(let current) = state, current.token == load.token {
        if load.handle.result() != nil {
          state = .empty
        } else if load.handle.quarantine() {
          load.task.cancel()
          state = .draining(.textLoad(load))
        }
      }
      throw Self.normalizeLoad(error)
    }
  }

  /// Loads an explicitly prepared text artifact and publishes the only public text invocation surface.
  /// This function never downloads or resolves a repository.
  public func makeTextRuntime(
    _ prepared: LeapPreparedTextModel,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) async throws -> ModelRuntime {
    let model = prepared.model
    try await load(prepared)
    let providerID = "leap.text"
    let descriptor = ModelDescriptor(
      id: "lfm2.5-qad-\(model.manifestDigest.rawValue)",
      providerID: providerID,
      displayName: model.displayName ?? "LEAP LFM2.5 QAD",
      capabilities: LeapModelClient.supportedCapabilities
    )
    let client = LeapModelClient(
      runtime: self,
      model: model,
      providerID: providerID,
      modelDescriptor: descriptor
    )
    return try ModelRuntime(
      id: runtimeID ?? ModelRuntimeID(rawValue: "leap.text.\(model.manifestDigest.rawValue)"),
      model: try ClientLanguageModel(client: client, descriptor: descriptor),
      policy: policy,
      // The host-owned runtime is the authoritative resident lifecycle owner.
      // This ModelRuntime only owns its invocation slot and borrows the resident.
      cleanup: {}
    )
  }

  public func load(_ model: LeapVoiceModel) async throws {
    try ensureHealthy()
    if case .voice(let resident) = state, !operationActive,
      resident.model.identity == model.identity
    {
      return
    }
    if case .loadingVoice(let loading) = state, loading.model.identity == model.identity {
      do {
        _ = try await waitForVoiceLoad(loading, cancellation: nil, owner: false)
        try await waitForVoiceLoadCommit(loading)
      } catch {
        throw Self.normalizeLoad(error)
      }
      return
    }
    try beginOperation()
    let cancellation = LeapLifecycleCancellation()
    lifecycleCancellation = cancellation
    defer {
      lifecycleCancellation = nil
      activeNativeTask = nil
      operationActive = false
    }
    try await reapDrain()
    try checkLifecycleCancellation(cancellation)
    try ensureHealthy()
    if case .voice(let resident) = state, resident.model.identity == model.identity {
      return
    }
    switch state {
    case .voice, .text:
      try await unloadResident()
    case .empty:
      break
    case .loadingVoice, .loadingText:
      throw LeapError.busy
    case .draining, .poisoned:
      throw LeapError.busy
    }

    try checkLifecycleCancellation(cancellation)
    let artifactLease = try await takeOrOpenArtifact(model.manifest)
    do {
      try checkLifecycleCancellation(cancellation)
    } catch {
      artifactLease.close()
      throw error
    }
    let processLease: any LeapProcessResidencyLease
    do {
      processLease = try claimResidency()
    } catch {
      artifactLease.close()
      throw error
    }
    do {
      try checkLifecycleCancellation(cancellation)
    } catch {
      artifactLease.close()
      processLease.close()
      throw error
    }
    let load = makeVoiceLoad(
      token: UUID(), model: model, artifactLease: artifactLease, processLease: processLease)
    state = .loadingVoice(load)
    activeNativeTask = load.task
    do {
      let session = try await waitForVoiceLoad(load, cancellation: cancellation, owner: true)
      if let beforeLoadCommit { await beforeLoadCommit() }
      do {
        try checkLifecycleCancellation(cancellation)
      } catch let cancellationError {
        do {
          try await cleanupVoiceLoadSession(
            session, artifactLease: artifactLease, processLease: processLease, token: load.token)
        } catch {
          throw error
        }
        throw cancellationError
      }
      guard case .loadingVoice(let current) = state, current.token == load.token else {
        try await cleanupVoiceLoadSession(
          session, artifactLease: artifactLease, processLease: processLease, token: load.token)
        throw LeapError.busy
      }
      state = .voice(
        VoiceResident(
          model: model, artifactLease: artifactLease, processLease: processLease, session: session))
    } catch {
      if case .loadingVoice(let current) = state, current.token == load.token {
        if load.handle.result() != nil {
          state = .empty
        } else if load.handle.quarantine() {
          load.task.cancel()
          state = .draining(.voiceLoad(load))
        }
      }
      throw Self.normalizeLoad(error)
    }
  }

  public func remove(_ model: LeapTextModel) async throws {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain()
    if case .text(let resident) = state, resident.model.identity == model.identity {
      try await unloadResident()
    }
    invalidateVerifiedArtifact(model.manifest)
    try await store.remove(model.manifest)
  }

  public func remove(_ model: LeapVoiceModel) async throws {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain()
    if case .voice(let resident) = state, resident.model.identity == model.identity {
      try await unloadResident()
    }
    invalidateVerifiedArtifact(model.manifest)
    try await store.remove(model.manifest)
  }

  func waitForNativeDrain() async throws {
    try await Task.detached { try await self.joinNativeDrain() }.value
  }

  private func joinNativeDrain() async throws {
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain(waitForCompletion: true)
  }

  public func unload() async throws {
    if operationActive {
      guard let lifecycleCancellation else { throw LeapError.busy }
      lifecycleCancellation.cancel()
      activeNativeTask?.cancel()
      while operationActive {
        try Task.checkCancellation()
        try await Task.sleep(for: LeapRuntimeScheduling.lifecyclePoll)
      }
    }
    try beginOperation()
    defer { operationActive = false }
    try await reapDrain(waitForCompletion: true)
    try await unloadResident()
  }

  public func handleMemoryWarning() async throws { try await unload() }

  public func handleBackgroundEntry(pinned: Bool = false) async throws {
    guard !pinned else { return }
    try await unload()
  }

  public func handleThermalState(_ thermalState: ProcessInfo.ThermalState) async throws {
    guard thermalState == .serious || thermalState == .critical else { return }
    try await unload()
  }

  func generate(
    for model: LeapVoiceModel,
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws {
    try request.validate()
    // Voice generators retain the historical prepare-then-generate flow, but
    // the selected model is explicit and the same load state is shared with
    // callers that invoke `load` directly. Text generation intentionally has
    // no equivalent implicit load.
    if !(isVoiceResident(model)) {
      try await load(model)
    }
    try beginOperation()
    let cancellation = LeapLifecycleCancellation()
    lifecycleCancellation = cancellation
    defer {
      lifecycleCancellation = nil
      activeNativeTask = nil
      operationActive = false
    }
    try await reapDrain()
    try Task.checkCancellation()
    guard case .voice(let resident) = state,
      resident.model.identity == model.identity
    else {
      switch state {
      case .loadingVoice, .loadingText, .draining: throw LeapError.busy
      default: throw LeapError.modelMissing
      }
    }

    let handle = LeapGenerationHandle()
    let generationState = LeapGenerationState()
    let session = resident.session
    let artifactLease = resident.artifactLease
    let processLease = resident.processLease
    let observedEmit: @Sendable (LeapVoiceEvent) -> Void = { event in
      if generationState.observe(event) { emit(event) }
    }
    let task = Task {
      let result: Result<Void, any Error>
      do {
        try await session.generate(request: request, emit: observedEmit)
        if Task.isCancelled {
          result = .failure(CancellationError())
        } else if let failure = generationState.failureValue() {
          result = .failure(failure)
        } else {
          result =
            generationState.hasValidTerminal()
            ? .success(())
            : .failure(LeapError.invalidRuntimeOutput)
        }
      } catch {
        result = .failure(error)
      }
      if handle.finish(result) {
        do {
          try await shutdownVoiceSession(session)
          artifactLease.close()
          processLease.close()
        } catch {
          processLease.poison(retaining: [session, artifactLease])
          handle.markCleanupFailure()
        }
      }
    }
    activeNativeTask = task
    let started = DispatchTime.now().uptimeNanoseconds
    while true {
      if let failure = generationState.failureValue(), handle.quarantine() {
        task.cancel()
        state = .draining(.voiceGeneration(handle: handle, task: task, resident: resident))
        throw failure
      }
      if cancellation.isCancelled || Task.isCancelled, handle.quarantine() {
        task.cancel()
        state = .draining(.voiceGeneration(handle: handle, task: task, resident: resident))
        throw CancellationError()
      }
      if let result = handle.result() {
        do {
          try result.get()
          return
        } catch {
          try await unloadResident()
          throw Self.normalize(error)
        }
      }
      if DispatchTime.now().uptimeNanoseconds &- started >= watchdog.totalNanoseconds,
        handle.quarantine()
      {
        task.cancel()
        state = .draining(.voiceGeneration(handle: handle, task: task, resident: resident))
        throw LeapError.generationTimedOut
      }
      if generationState.inactivityNanoseconds() >= watchdog.inactivityNanoseconds,
        handle.quarantine()
      {
        task.cancel()
        state = .draining(.voiceGeneration(handle: handle, task: task, resident: resident))
        throw LeapError.generationStalled
      }
      try? await Task.sleep(for: LeapRuntimeScheduling.watchdogPoll)
    }
  }

  func generateTextStream(
    for model: LeapTextModel,
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat = .text,
    emit: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    guard !userMessage.isEmpty else { throw LeapError.invalidRequest }
    try outputFormat.validate()
    try beginOperation()
    let cancellation = LeapLifecycleCancellation()
    lifecycleCancellation = cancellation
    defer {
      lifecycleCancellation = nil
      activeNativeTask = nil
      operationActive = false
    }
    // Reap before touching the runner. A non-cooperative native call keeps the
    // state draining and all reuse attempts busy until its task exits.
    try await reapDrain()
    try Task.checkCancellation()
    guard case .text(let resident) = state,
      resident.model.identity == model.identity
    else {
      switch state {
      case .loadingVoice, .loadingText, .draining: throw LeapError.busy
      default: throw LeapError.modelMissing
      }
    }

    let generationState = LeapTextGenerationState()
    let handle = LeapGenerationHandle()
    let session = resident.session
    let artifactLease = resident.artifactLease
    let processLease = resident.processLease
    let task = Task {
      let result: Result<Void, any Error>
      do {
        try await session.generate(
          history: history,
          userMessage: userMessage,
          outputFormat: outputFormat,
          emit: { event in
            switch event {
            case .text(let chunk):
              if let value = generationState.observe(chunk) { emit(value) }
            case .completed:
              generationState.observeCompletion()
            }
          })
        if Task.isCancelled {
          result = .failure(CancellationError())
        } else if let failure = generationState.failureValue() {
          result = .failure(failure)
        } else {
          result =
            generationState.hasValidTerminal()
            ? .success(())
            : .failure(LeapError.invalidRuntimeOutput)
        }
      } catch {
        result = .failure(error)
      }
      if handle.finish(result) {
        do {
          try await shutdownTextSession(session)
          artifactLease.close()
          processLease.close()
        } catch {
          processLease.poison(retaining: [LeapTextRunnerBox(session), artifactLease])
          handle.markCleanupFailure()
        }
      }
    }
    activeNativeTask = task
    let started = DispatchTime.now().uptimeNanoseconds
    while true {
      if let failure = generationState.failureValue(), handle.quarantine() {
        task.cancel()
        state = .draining(.textGeneration(handle: handle, task: task, resident: resident))
        throw failure
      }
      if cancellation.isCancelled || Task.isCancelled, handle.quarantine() {
        task.cancel()
        state = .draining(.textGeneration(handle: handle, task: task, resident: resident))
        throw CancellationError()
      }
      if let result = handle.result() {
        do {
          try result.get()
          guard let output = generationState.accumulatedText(), !output.isEmpty else {
            throw LeapError.invalidRuntimeOutput
          }
          return output
        } catch {
          try await unloadResident()
          throw Self.normalize(error)
        }
      }
      if DispatchTime.now().uptimeNanoseconds &- started >= watchdog.totalNanoseconds,
        handle.quarantine()
      {
        task.cancel()
        state = .draining(.textGeneration(handle: handle, task: task, resident: resident))
        throw LeapError.generationTimedOut
      }
      if generationState.inactivityNanoseconds() >= watchdog.inactivityNanoseconds,
        handle.quarantine()
      {
        task.cancel()
        state = .draining(.textGeneration(handle: handle, task: task, resident: resident))
        throw LeapError.generationStalled
      }
      try? await Task.sleep(for: LeapRuntimeScheduling.watchdogPoll)
    }
  }

  private func beginOperation() throws {
    try Task.checkCancellation()
    try ensureHealthy()
    guard !operationActive else { throw LeapError.busy }
    operationActive = true
  }

  private func checkLifecycleCancellation(
    _ cancellation: LeapLifecycleCancellation
  ) throws {
    try Task.checkCancellation()
    if cancellation.isCancelled { throw CancellationError() }
  }

  private func isVoiceResident(_ model: LeapVoiceModel) -> Bool {
    guard case .voice(let resident) = state else { return false }
    return resident.model.identity == model.identity
  }

  private func ensureHealthy() throws {
    if case .poisoned = state { throw LeapError.nativeFailure }
    guard !residency.isPoisoned() else {
      state = .poisoned
      throw LeapError.nativeFailure
    }
  }

  private func claimResidency() throws -> any LeapProcessResidencyLease {
    do { return try residency.claim(residencyID) } catch ProcessResidencyError.busy {
      throw LeapError.busy
    }
  }

  private func cacheVerifiedArtifact(_ lease: ArtifactLease) {
    let manifest = lease.manifest
    if let previous = verifiedArtifacts.updateValue(lease, forKey: manifest), previous !== lease {
      previous.close()
    }
    verifiedArtifactOrder.removeAll { $0 == manifest }
    verifiedArtifactOrder.append(manifest)
    while verifiedArtifactOrder.count > Self.verifiedArtifactCacheLimit {
      let evictedManifest = verifiedArtifactOrder.removeFirst()
      guard let evicted = verifiedArtifacts.removeValue(forKey: evictedManifest) else { continue }
      evicted.close()
    }
  }

  private func takeVerifiedArtifact(_ manifest: ArtifactManifest) -> ArtifactLease? {
    guard let lease = verifiedArtifacts.removeValue(forKey: manifest) else { return nil }
    verifiedArtifactOrder.removeAll { $0 == manifest }
    return lease
  }

  private func invalidateVerifiedArtifact(_ manifest: ArtifactManifest) {
    guard let lease = verifiedArtifacts.removeValue(forKey: manifest) else { return }
    verifiedArtifactOrder.removeAll { $0 == manifest }
    lease.close()
  }

  private func takeOrOpenArtifact(_ manifest: ArtifactManifest) async throws -> ArtifactLease
  {
    if let lease = takeVerifiedArtifact(manifest) { return lease }
    return try await openArtifact(manifest)
  }

  private func openVerifiedArtifact(_ manifest: ArtifactManifest) async throws
    -> ArtifactLease
  {
    if let beforeArtifactOpen { await beforeArtifactOpen() }
    artifactOpenObserver?()
    return try await store.open(manifest)
  }

  private func openArtifact(_ manifest: ArtifactManifest) async throws -> ArtifactLease {
    do { return try await openVerifiedArtifact(manifest) } catch ArtifactStoreError.missingFile {
      throw LeapError.modelMissing
    } catch { throw Self.normalizeArtifact(error) }
  }

  private func prepareArtifact(
    repositoryID: String,
    revision: String,
    manifest: ArtifactManifest,
    progress: (@Sendable (LeapDownloadProgress) -> Void)?
  ) async throws {
    if verifiedArtifacts[manifest] != nil {
      try Task.checkCancellation()
      return
    }
    do {
      let lease = try await openVerifiedArtifact(manifest)
      do {
        try Task.checkCancellation()
      } catch {
        lease.close()
        throw error
      }
      cacheVerifiedArtifact(lease)
      return
    } catch let error as ArtifactStoreError where Self.repairable(error) {
      try Task.checkCancellation()
    } catch {
      try Task.checkCancellation()
      throw error
    }
    let staging = try await store.beginStaging(for: manifest)
    do {
      try Task.checkCancellation()
      try await downloader.download(
        repositoryID: repositoryID,
        revision: revision,
        manifest: manifest,
        into: staging,
        progress: progress)
      try Task.checkCancellation()
      let lease = try await store.publish(staging)
      do {
        try Task.checkCancellation()
      } catch {
        lease.close()
        throw error
      }
      cacheVerifiedArtifact(lease)
      return
    } catch {
      staging.abandon()
      if error is CancellationError { throw CancellationError() }
      throw Self.normalizeArtifact(error)
    }
  }

  private func importArtifact(_ manifest: ArtifactManifest, from directoryURL: URL) async throws
  {
    if verifiedArtifacts[manifest] != nil {
      try Task.checkCancellation()
      return
    }
    do {
      let lease = try await openVerifiedArtifact(manifest)
      do {
        try Task.checkCancellation()
      } catch {
        lease.close()
        throw error
      }
      cacheVerifiedArtifact(lease)
      return
    } catch let error as ArtifactStoreError where Self.repairable(error) {
      try Task.checkCancellation()
    } catch {
      try Task.checkCancellation()
      throw error
    }
    let staging = try await store.beginStaging(for: manifest)
    do {
      try Task.checkCancellation()
      try staging.importFiles(from: directoryURL)
      try Task.checkCancellation()
      let lease = try await store.publish(staging)
      do {
        try Task.checkCancellation()
      } catch {
        lease.close()
        throw error
      }
      cacheVerifiedArtifact(lease)
      return
    } catch {
      staging.abandon()
      if error is CancellationError { throw CancellationError() }
      throw Self.normalizeArtifact(error)
    }
  }

  private func makeVoiceLoad(
    token: UUID,
    model: LeapVoiceModel,
    artifactLease: ArtifactLease,
    processLease: any LeapProcessResidencyLease
  ) -> VoiceLoad {
    let handle = LeapLoadHandle()
    let loader = self.loader
    let task = Task {
      do {
        let session = try await loader.load(artifactLease.directoryURL)
        if handle.finish(.success(session)) {
          do {
            try await shutdownVoiceSession(session)
            artifactLease.close()
            processLease.close()
          } catch {
            processLease.poison(retaining: [session, artifactLease])
            handle.markCleanupFailure()
          }
        }
      } catch {
        _ = handle.finish(.failure(error))
        artifactLease.close()
        processLease.close()
      }
    }
    return VoiceLoad(
      token: token, model: model, handle: handle, task: task, artifactLease: artifactLease,
      processLease: processLease)
  }

  private func makeTextLoad(
    token: UUID,
    model: LeapTextModel,
    artifactLease: ArtifactLease,
    processLease: any LeapProcessResidencyLease,
    modelURL: URL
  ) -> TextLoad {
    let handle = LeapTextLoadHandle()
    let loader = self.textLoader
    let task = Task {
      do {
        let session = try await loader.load(modelURL)
        if handle.finish(.success(session)) {
          do {
            try await shutdownTextSession(session)
            artifactLease.close()
            processLease.close()
          } catch {
            processLease.poison(retaining: [LeapTextRunnerBox(session), artifactLease])
            handle.markCleanupFailure()
          }
        }
      } catch {
        _ = handle.finish(.failure(error))
        artifactLease.close()
        processLease.close()
      }
    }
    return TextLoad(
      token: token, model: model, handle: handle, task: task, artifactLease: artifactLease,
      processLease: processLease, modelURL: modelURL)
  }

  private func waitForVoiceLoad(
    _ load: VoiceLoad,
    cancellation: LeapLifecycleCancellation?,
    owner: Bool
  ) async throws -> any LeapVoiceSession {
    while true {
      if let result = load.handle.result() { return try result.get() }
      if (owner && cancellation?.isCancelled == true) || (owner && Task.isCancelled) {
        if load.handle.quarantine() {
          load.task.cancel()
          if case .loadingVoice(let current) = state, current.token == load.token {
            state = .draining(.voiceLoad(load))
          }
        }
        throw CancellationError()
      }
      if !owner, Task.isCancelled { throw CancellationError() }
      try? await Task.sleep(for: LeapRuntimeScheduling.loadResultPoll)
    }
  }

  private func waitForVoiceLoadCommit(_ load: VoiceLoad) async throws {
    while true {
      switch state {
      case .voice(let resident) where resident.model.identity == load.model.identity:
        return
      case .loadingVoice(let current) where current.token == load.token:
        if let result = load.handle.result() {
          do {
            _ = try result.get()
          } catch {
            throw Self.normalizeLoad(error)
          }
        }
      case .draining:
        throw LeapError.busy
      case .poisoned:
        throw LeapError.nativeFailure
      case .empty:
        if let result = load.handle.result() {
          do {
            _ = try result.get()
            throw LeapError.busy
          } catch {
            throw Self.normalizeLoad(error)
          }
        }
      default:
        throw LeapError.busy
      }
      try Task.checkCancellation()
      try await Task.sleep(for: LeapRuntimeScheduling.lifecyclePoll)
    }
  }

  private func waitForTextLoad(
    _ load: TextLoad,
    cancellation: LeapLifecycleCancellation?,
    owner: Bool
  ) async throws -> any LeapTextSession {
    while true {
      if let result = load.handle.result() { return try result.get() }
      if (owner && cancellation?.isCancelled == true) || (owner && Task.isCancelled) {
        if load.handle.quarantine() {
          load.task.cancel()
          if case .loadingText(let current) = state, current.token == load.token {
            state = .draining(.textLoad(load))
          }
        }
        throw CancellationError()
      }
      if !owner, Task.isCancelled { throw CancellationError() }
      try? await Task.sleep(for: LeapRuntimeScheduling.loadResultPoll)
    }
  }

  private func waitForTextLoadCommit(_ load: TextLoad) async throws {
    while true {
      switch state {
      case .text(let resident) where resident.model.identity == load.model.identity:
        return
      case .loadingText(let current) where current.token == load.token:
        if let result = load.handle.result() {
          do {
            _ = try result.get()
          } catch {
            throw Self.normalizeLoad(error)
          }
        }
      case .draining:
        throw LeapError.busy
      case .poisoned:
        throw LeapError.nativeFailure
      case .empty:
        if let result = load.handle.result() {
          do {
            _ = try result.get()
            throw LeapError.busy
          } catch {
            throw Self.normalizeLoad(error)
          }
        }
      default:
        throw LeapError.busy
      }
      try Task.checkCancellation()
      try await Task.sleep(for: LeapRuntimeScheduling.lifecyclePoll)
    }
  }

  private func reapDrain(waitForCompletion: Bool = false) async throws {
    if let beforeReapDrain { await beforeReapDrain() }
    try Task.checkCancellation()
    guard case .draining(let drain) = state else { return }
    switch drain {
    case .voiceGeneration(let handle, let task, _),
      .textGeneration(let handle, let task, _):
      try await waitForDrain(handle: handle, task: task, waitForCompletion: waitForCompletion)
    case .voiceLoad(let load):
      try await waitForDrain(
        handle: load.handle, task: load.task, waitForCompletion: waitForCompletion)
    case .textLoad(let load):
      try await waitForDrain(
        handle: load.handle, task: load.task, waitForCompletion: waitForCompletion)
    }
    state = .empty
  }

  private func waitForDrain<Value: Sendable>(
    handle: LeapResultHandle<Value>,
    task: Task<Void, Never>,
    waitForCompletion: Bool
  ) async throws {
    if waitForCompletion {
      while handle.result() == nil {
        try Task.checkCancellation()
        try await Task.sleep(for: LeapRuntimeScheduling.lifecyclePoll)
      }
    } else {
      guard handle.result() != nil else { throw LeapError.busy }
    }
    _ = await task.result
    guard !handle.didCleanupFail() else {
      state = .poisoned
      throw LeapError.nativeFailure
    }
  }

  private func cleanupTextLoadSession(
    _ session: any LeapTextSession,
    artifactLease: ArtifactLease,
    processLease: any LeapProcessResidencyLease,
    token: UUID
  ) async throws {
    do {
      try await shutdownTextSession(session)
    } catch {
      processLease.poison(retaining: [LeapTextRunnerBox(session), artifactLease])
      if case .loadingText(let current) = state, current.token == token {
        state = .poisoned
      }
      throw LeapError.nativeFailure
    }
    artifactLease.close()
    processLease.close()
  }

  private func cleanupVoiceLoadSession(
    _ session: any LeapVoiceSession,
    artifactLease: ArtifactLease,
    processLease: any LeapProcessResidencyLease,
    token: UUID
  ) async throws {
    do {
      try await shutdownVoiceSession(session)
    } catch {
      processLease.poison(retaining: [session, artifactLease])
      if case .loadingVoice(let current) = state, current.token == token {
        state = .poisoned
      }
      throw LeapError.nativeFailure
    }
    artifactLease.close()
    processLease.close()
  }

  private func unloadResident() async throws {
    switch state {
    case .empty:
      return
    case .voice(let resident):
      state = .empty
      do {
        try await shutdownVoiceSession(resident.session)
        cacheVerifiedArtifact(resident.artifactLease)
        resident.processLease.close()
      } catch {
        resident.processLease.poison(retaining: [resident.session, resident.artifactLease])
        state = .poisoned
        throw LeapError.nativeFailure
      }
    case .text(let resident):
      state = .empty
      do {
        try await shutdownTextSession(resident.session)
        cacheVerifiedArtifact(resident.artifactLease)
        resident.processLease.close()
      } catch {
        resident.processLease.poison(
          retaining: [LeapTextRunnerBox(resident.session), resident.artifactLease])
        state = .poisoned
        throw LeapError.nativeFailure
      }
    case .loadingVoice, .loadingText, .draining:
      throw LeapError.busy
    case .poisoned:
      throw LeapError.nativeFailure
    }
  }

  private static func repairable(_ error: ArtifactStoreError) -> Bool {
    switch error {
    case .missingFile, .unsupportedEntry, .sizeMismatch, .digestMismatch: true
    default: false
    }
  }

  private static func normalizeArtifact(_ error: any Error) -> LeapError {
    if let error = error as? LeapError { return error }
    if let error = error as? ArtifactStoreError {
      switch error {
      case .missingFile: return .modelMissing
      case .limitExceeded: return .insufficientDisk
      case .invalidManifest, .invalidPath, .unsupportedEntry, .sizeMismatch,
        .digestMismatch, .consumedStaging:
        return .invalidArtifact
      case .busy, .storageFailure: return .nativeFailure
      }
    }
    if error is CancellationError { return .generationInterrupted }
    return .nativeFailure
  }

  private static func normalizeLoad(_ error: any Error) -> any Error {
    if error is CancellationError { return CancellationError() }
    if let error = error as? LeapError { return error }
    return LeapError.nativeFailure
  }

  private static func normalize(_ error: any Error) -> any Error {
    if error is CancellationError { return CancellationError() }
    if let error = error as? LeapError { return error }
    return LeapError.nativeFailure
  }
}
