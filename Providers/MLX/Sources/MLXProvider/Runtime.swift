import ModelArtifactStore
import MLXModelRegistry
import Foundation
import LanguageModelCore
import LanguageModelRuntime
import ModelHub

public enum MLXTextError: Error, Equatable, Sendable {
  case invalidModel
  case modelMissing
  case busy
  case insufficientDisk
  case invalidArtifact
  case invalidRuntimeOutput
}

public enum MLXReadiness: Equatable, Sendable { case missing, ready, busy }

/// Immutable proof that model bytes were resolved, verified, and atomically
/// published before any attempt to load MLX resources into memory.
public struct MLXPreparedModel: Sendable, Hashable {
  public let model: MLXModel
  let specification: MLXModelSpecification

}

private typealias MLXProcessLease = ProcessResidencyLease

private final class MLXLifecycleCancellation: @unchecked Sendable {
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

private typealias MLXGenerationHandle = MLXResultHandle<Void>
typealias MLXLoadHandle = MLXResultHandle<any MLXLoadedSession>

public actor MLXTextRuntime {
  private struct Resident {
    let specification: MLXModelSpecification
    let lease: ArtifactLease
    let session: any MLXLoadedSession
  }

  private enum Drain: Sendable {
    case generation(handle: MLXGenerationHandle, task: Task<Void, Never>)
    case load(
      handle: MLXLoadHandle,
      task: Task<Void, Never>,
      lease: ArtifactLease)
  }

  private let store: ModelArtifactStore
  private let resolver: MLXHubArtifactResolver
  private let loader: MLXSessionLoader
  private var resolvedSpecifications: [MLXModel: MLXModelSpecification] = [:]
  private var residencyLease: MLXProcessLease?
  private var resident: Resident?
  private var drain: Drain?
  private var operationActive = false
  private var lifecycleCancellation: MLXLifecycleCancellation?
  private var activeNativeTask: Task<Void, Never>?
  private var persistenceFailure: MLXTextPersistenceError?

  private let specificationsPersistenceURL: URL?

  static func modelDescriptor(for model: MLXModel) -> ModelDescriptor {
    ModelDescriptor(
      id: "\(model.repositoryID)@\(model.revision)",
      providerID: "mlx.text",
      displayName: model.repositoryID,
      capabilities: [.textInput, .textOutput, .streaming, .toolCalls, .structuredOutput])
  }

  public init(store: ModelArtifactStore) {
    self.init(store: store, specificationsPersistenceURL: nil)
  }

  /// `specificationsPersistenceURL` lets resolved Hub specifications survive
  /// process restarts; without it a restarted app reports a downloaded model
  /// as missing until it resolves against the Hub again.
  public init(
    store: ModelArtifactStore,
    specificationsPersistenceURL: URL?
  ) {
    self.init(
      store: store,
      artifactResolver: MLXHubArtifactResolver(),
      specificationsPersistenceURL: specificationsPersistenceURL)
  }

  /// Creates a runtime that uses the supplied Hub resolver. Hosts can pass an authenticated
  /// resolver when a user has access to a gated or private model repository.
  public init(
    store: ModelArtifactStore,
    artifactResolver: MLXHubArtifactResolver,
    specificationsPersistenceURL: URL? = nil
  ) {
    self.store = store
    self.resolver = artifactResolver
    self.loader = .live
    self.specificationsPersistenceURL = specificationsPersistenceURL
  }

  init(
    store: ModelArtifactStore,
    loader: MLXSessionLoader,
    specificationsPersistenceURL: URL? = nil
  ) {
    self.store = store
    self.resolver = MLXHubArtifactResolver()
    self.loader = loader
    self.specificationsPersistenceURL = specificationsPersistenceURL
  }

  nonisolated func modelClient(for model: MLXModel) -> MLXTextModelClient {
    MLXTextModelClient(runtime: self, model: model)
  }

  public func readiness(for model: MLXModel) async throws -> MLXReadiness {
    try loadPersistedSpecificationsIfNeeded()
    guard let specification = resolvedSpecifications[model] else { return .missing }
    return try await readiness(specification: specification)
  }

  func readiness(specification: MLXModelSpecification) async throws -> MLXReadiness {
    guard !operationActive else { return .busy }
    operationActive = true
    defer { operationActive = false }
    do { try await reapDrain() } catch MLXTextError.busy { return .busy }
    if resident?.specification == specification { return .ready }
    do {
      let lease = try await store.open(specification.manifest)
      lease.close()
      return .ready
    } catch ArtifactStoreError.missingFile { return .missing }
  }

  @discardableResult
  public func prepare(
    _ model: MLXModel,
    progress: (@Sendable (MLXDownloadProgress) -> Void)? = nil
  ) async throws -> MLXPreparedModel {
    let specification = try await resolve(model, progress: progress)
    return MLXPreparedModel(model: model, specification: specification)
  }

  /// Resolves a Hugging Face repository address to an immutable commit, downloads and verifies its
  /// MLX text files, and publishes a prepared model. The address can be `namespace/repository`, a
  /// Hugging Face model URL, or a `/tree/<revision>` URL.
  public func prepare(
    from address: String,
    progress: (@Sendable (MLXDownloadProgress) -> Void)? = nil
  ) async throws -> MLXPreparedModel {
    try await prepare(from: MLXHubModelAddress(address), progress: progress)
  }

  public func prepare(
    from address: MLXHubModelAddress,
    progress: (@Sendable (MLXDownloadProgress) -> Void)? = nil
  ) async throws -> MLXPreparedModel {
    let reference = try await resolver.resolveReference(for: address)
    let model = try MLXModel(
      repositoryID: reference.repositoryID,
      revision: reference.revision)
    return try await prepare(model, progress: progress)
  }

  /// Metadata-only compatibility check used by the cross-provider Hugging Face installer.
  public func inspectHubModel(
    at address: HubModelAddress
  ) async throws -> MLXHubModelInspection? {
    let mlxAddress = try MLXHubModelAddress(address.pageAddress)
    let reference = try await resolver.resolveReference(for: mlxAddress)
    return try await resolver.inspect(reference: reference, policy: .mlxText)
  }

  /// Rehydrates the model catalog captured by `specificationsPersistenceURL`.
  /// Multiple runtime settings for the same Hub commit are represented once, preferring defaults.
  public func registeredModels() throws -> [MLXModel] {
    try loadPersistedSpecificationsIfNeeded()
    let candidates = Array(Set(resolvedSpecifications.keys)).sorted {
      let leftID = Self.registryModelID($0)
      let rightID = Self.registryModelID($1)
      if leftID != rightID { return leftID < rightID }
      let leftDefault = Self.isDefaultRegistryConfiguration($0)
      let rightDefault = Self.isDefaultRegistryConfiguration($1)
      if leftDefault != rightDefault { return leftDefault }
      return Self.registryConfigurationKey($0) < Self.registryConfigurationKey($1)
    }
    var selected: [String: MLXModel] = [:]
    for model in candidates {
      let id = Self.registryModelID(model)
      if selected[id] == nil { selected[id] = model }
    }
    return selected.values.sorted { Self.registryModelID($0) < Self.registryModelID($1) }
  }

  private static func registryModelID(_ model: MLXModel) -> String {
    "\(model.repositoryID)@\(model.revision)"
  }

  private static func isDefaultRegistryConfiguration(_ model: MLXModel) -> Bool {
    model.extraEOSTokens.isEmpty && !model.disablesThinking && model.sampling == .default
  }

  private static func registryConfigurationKey(_ model: MLXModel) -> String {
    "\(model.extraEOSTokens.sorted().joined(separator: ","))|\(model.disablesThinking)|\(model.sampling.temperature)|\(model.sampling.topP)|\(model.sampling.topK)|\(model.sampling.repetitionPenalty)"
  }

  /// Loads an already-published snapshot and only then exposes a ready ModelRuntime.
  /// This method never performs Hub lookup or network preparation.
  public func loadRuntime(
    _ prepared: MLXPreparedModel,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) async throws -> ModelRuntime {
    try beginOperation()
    let cancellation = MLXLifecycleCancellation()
    lifecycleCancellation = cancellation
    defer {
      lifecycleCancellation = nil
      activeNativeTask = nil
      endOperation()
    }
    try await reapDrain()
    try Task.checkCancellation()
    try await ensureResident(
      specification: prepared.specification,
      cancellation: cancellation
    )

    let providerID = "mlx.text"
    let descriptor = Self.modelDescriptor(for: prepared.model)
    let client = MLXTextModelClient(
      runtime: self,
      specification: prepared.specification,
      providerID: providerID,
      modelDescriptor: descriptor
    )
    return try ModelRuntime(
      id: runtimeID ?? ModelRuntimeID(rawValue: "mlx.text.\(prepared.model.repositoryID)"),
      client: client,
      descriptor: descriptor,
      policy: policy,
      // The host-owned runtime is the authoritative resident lifecycle owner.
      // This ModelRuntime only owns its invocation slot and borrows the resident.
      cleanup: {}
    )
  }

  /// One-call path for a host that accepts a model URL at runtime. It resolves the current Hub
  /// revision, downloads it once into the artifact store, loads it, and returns a ready runtime.
  public func loadRuntime(
    from address: String,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default,
    progress: (@Sendable (MLXDownloadProgress) -> Void)? = nil
  ) async throws -> ModelRuntime {
    let prepared = try await prepare(from: address, progress: progress)
    return try await loadRuntime(prepared, runtimeID: runtimeID, policy: policy)
  }

  private func resolve(
    _ model: MLXModel,
    progress: (@Sendable (MLXDownloadProgress) -> Void)?
  ) async throws -> MLXModelSpecification {
    try loadPersistedSpecificationsIfNeeded()
    if let persistenceFailure { throw persistenceFailure }
    // Sampling settings do not change the immutable artifact bytes. Reuse a
    // verified manifest for the same Hub revision before considering network I/O.
    if let cached = resolvedSpecifications[model]
      ?? resolvedSpecifications.values.first(where: { $0.model.hubReference == model.hubReference }) {
      do {
        let lease = try await store.open(cached.manifest)
        lease.close()
        let specification = try MLXModelSpecification(
          model: model, resolvedReference: model.hubReference, resolvedManifest: cached.manifest)
        if resolvedSpecifications[model] == nil {
          resolvedSpecifications[model] = specification
          do { try persistResolvedSpecifications() } catch let error as MLXTextPersistenceError {
            resolvedSpecifications.removeValue(forKey: model)
            persistenceFailure = error
            throw error
          }
        }
        return specification
      } catch let error as ArtifactStoreError where Self.repairableArtifact(error) {
        // The immutable reference remains authoritative. Missing or positively
        // corrupted bytes are repaired through the same Hub materialization
        // effect as the first prepare; there is no second downloader path.
      }
    }
    let resolved = try await resolver.materialize(
      reference: model.hubReference,
      policy: .mlxText,
      store: store,
      progress: { value in
        progress?(
          .init(
            completedBytes: value.completedBytes,
            totalBytes: value.totalBytes,
            currentFile: value.currentFile))
      })
    let specification = try MLXModelSpecification(
      model: model,
      resolvedReference: resolved.reference,
      resolvedManifest: resolved.manifest)
    resolvedSpecifications[model] = specification
    do { try persistResolvedSpecifications() } catch let error as MLXTextPersistenceError {
      resolvedSpecifications.removeValue(forKey: model)
      persistenceFailure = error
      throw error
    }
    return specification
  }

  private var persistedSpecificationsLoaded = false

  private func loadPersistedSpecificationsIfNeeded() throws {
    guard !persistedSpecificationsLoaded else { return }
    if let persistenceFailure { throw persistenceFailure }
    guard let url = specificationsPersistenceURL else {
      persistedSpecificationsLoaded = true
      return
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      persistedSpecificationsLoaded = true
      return
    }
    let entries: [MLXSpecificationArchive.Entry]
    do { entries = try MLXSpecificationArchive.load(from: url) } catch let error
      as MLXTextPersistenceError
    {
      persistenceFailure = error
      throw error
    }
    for entry in entries {
      if let existing = resolvedSpecifications[entry.model], existing != entry.specification {
        throw MLXTextPersistenceError.duplicateModel
      }
      resolvedSpecifications[entry.model] = entry.specification
    }
    persistedSpecificationsLoaded = true
  }

  private func persistResolvedSpecifications() throws {
    guard let url = specificationsPersistenceURL else { return }
    let entries = resolvedSpecifications.map {
      MLXSpecificationArchive.Entry(model: $0.key, specification: $0.value)
    }
    try MLXSpecificationArchive.save(
      entries.sorted {
        $0.model.repositoryID < $1.model.repositoryID
      }, to: url)
  }

  func waitForNativeDrain() async throws {
    try await Task.detached { try await self.joinNativeDrain() }.value
  }

  private func joinNativeDrain() async throws {
    try beginOperation()
    defer { endOperation() }
    try await reapDrain(waitForCompletion: true)
  }

  public func unload() async throws {
    if operationActive {
      guard let lifecycleCancellation else { throw MLXTextError.busy }
      lifecycleCancellation.cancel()
      activeNativeTask?.cancel()
      while operationActive {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    try beginOperation()
    defer { endOperation() }
    try await reapDrain(waitForCompletion: true)
    await unloadResident(releasingProcess: true)
  }

  /// Handles an iOS memory warning by cancelling active local work and waiting
  /// for the native runtime and its artifact lease to drain before unloading.
  public func handleMemoryWarning() async throws { try await unload() }

  /// Handles entry into the background. A pinned caller may keep the resident
  /// runtime alive when it has an explicit background execution contract.
  public func handleBackgroundEntry(pinned: Bool = false) async throws {
    guard !pinned else { return }
    try await unload()
  }

  /// Releases the resident runtime for serious or critical thermal pressure.
  public func handleThermalState(_ thermalState: ProcessInfo.ThermalState) async throws {
    guard thermalState == .serious || thermalState == .critical else { return }
    try await unload()
  }

  public func remove(_ model: MLXModel) async throws {
    try loadPersistedSpecificationsIfNeeded()
    if let persistenceFailure { throw persistenceFailure }
    guard let specification = resolvedSpecifications[model] else {
      throw MLXTextError.modelMissing
    }
    try await remove(specification: specification)
    resolvedSpecifications.removeValue(forKey: model)
    do { try persistResolvedSpecifications() } catch let error as MLXTextPersistenceError {
      persistenceFailure = error
      throw error
    }
  }

  func remove(specification: MLXModelSpecification) async throws {
    try beginOperation()
    defer { endOperation() }
    try await reapDrain()
    if resident?.specification == specification {
      await unloadResident(releasingProcess: true)
    }
    try await store.remove(specification.manifest)
  }

  func generate(
    specification: MLXModelSpecification,
    request: ModelRequest,
    emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws {
    try beginOperation()
    defer { endOperation() }
    let lifecycleCancellation = MLXLifecycleCancellation()
    self.lifecycleCancellation = lifecycleCancellation
    defer {
      self.lifecycleCancellation = nil
      activeNativeTask = nil
    }
    try await reapDrain()
    try Task.checkCancellation()
    try await ensureResident(
      specification: specification,
      cancellation: lifecycleCancellation
    )
    guard let resident, resident.specification == specification else {
      throw MLXTextError.invalidRuntimeOutput
    }
    let handle = MLXGenerationHandle()
    let processLease = residencyLease
    let loader = self.loader
    let task = Task {
      _ = processLease
      let result: Result<Void, any Error>
      do {
        try await resident.session.generate(request: request, emit: emit)
        result = .success(())
      } catch { result = .failure(error) }
      if handle.finish(result) {
        await resident.session.shutdown()
        resident.lease.close()
        await loader.clearCache()
        processLease?.close()
      }
    }
    activeNativeTask = task
    while true {
      if lifecycleCancellation.isCancelled || Task.isCancelled {
        if handle.quarantine() {
          task.cancel()
          drain = .generation(handle: handle, task: task)
          throw CancellationError()
        }
      }
      if let result = handle.result() {
        do {
          try result.get()
          return
        } catch {
          await unloadResident(releasingProcess: true)
          throw error
        }
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  func generate(
    model: MLXModel,
    request: ModelRequest,
    emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws {
    // Same offline restore as readiness(): an app restart must not force a UI
    // refresh round-trip before generation finds its persisted specification.
    try loadPersistedSpecificationsIfNeeded()
    guard let specification = resolvedSpecifications[model] else {
      throw MLXTextError.modelMissing
    }
    try await generate(specification: specification, request: request, emit: emit)
  }

  private func beginOperation() throws {
    try Task.checkCancellation()
    guard !operationActive else { throw MLXTextError.busy }
    operationActive = true
  }

  private func endOperation() { operationActive = false }

  private static func repairableArtifact(_ error: ArtifactStoreError) -> Bool {
    switch error {
    case .missingFile, .unsupportedEntry, .sizeMismatch, .digestMismatch:
      true
    case .invalidManifest, .invalidPath, .limitExceeded, .busy, .consumedStaging,
      .storageFailure:
      false
    }
  }

  private func reapDrain(waitForCompletion: Bool = false) async throws {
    guard let drain else { return }
    switch drain {
    case .generation(let handle, let task):
      if waitForCompletion {
        while handle.result() == nil {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(5))
        }
      } else {
        guard handle.result() != nil else { throw MLXTextError.busy }
      }
      _ = await task.result
      self.drain = nil
      resident = nil
      residencyLease = nil
    case .load(let handle, let task, let lease):
      if waitForCompletion {
        while handle.result() == nil {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(5))
        }
      } else {
        guard handle.result() != nil else { throw MLXTextError.busy }
      }
      _ = await task.result
      _ = lease
      self.drain = nil
      residencyLease = nil
    }
  }

  private func ensureResident(
    specification: MLXModelSpecification,
    cancellation: MLXLifecycleCancellation
  ) async throws {
    if resident?.specification == specification { return }

    let lease: ArtifactLease
    do {
      lease = try await store.open(specification.manifest)
    } catch ArtifactStoreError.missingFile {
      throw MLXTextError.modelMissing
    }

    do {
      if residencyLease == nil {
        do {
          residencyLease = try ProcessResidency.shared.claim()
        } catch ProcessResidencyError.busy {
          throw MLXTextError.busy
        }
      }
      await unloadResident(releasingProcess: false)
      let session = try await loadSession(
        lease: lease,
        specification: specification,
        cancellation: cancellation
      )
      resident = Resident(specification: specification, lease: lease, session: session)
    } catch {
      if drain == nil {
        lease.close()
        residencyLease?.close()
        residencyLease = nil
      }
      throw error
    }
  }

  private func loadSession(
    lease: ArtifactLease,
    specification: MLXModelSpecification,
    cancellation: MLXLifecycleCancellation
  ) async throws -> any MLXLoadedSession {
    let handle = MLXLoadHandle()
    let processLease = residencyLease
    let loader = self.loader
    let task = Task {
      do {
        let session = try await loader.load(lease.directoryURL, specification)
        if handle.finish(.success(session)) {
          await session.shutdown()
          lease.close()
          await loader.clearCache()
          processLease?.close()
        }
      } catch {
        if handle.finish(.failure(error)) {
          lease.close()
          await loader.clearCache()
          processLease?.close()
        }
      }
    }
    activeNativeTask = task
    defer { activeNativeTask = nil }
    while true {
      if cancellation.isCancelled || Task.isCancelled {
        if handle.quarantine() {
          task.cancel()
          drain = .load(handle: handle, task: task, lease: lease)
          throw CancellationError()
        }
      }
      if let result = handle.result() { return try result.get() }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func unloadResident(releasingProcess: Bool) async {
    if let old = resident {
      resident = nil
      await old.session.shutdown()
      old.lease.close()
      await loader.clearCache()
    }
    if releasingProcess {
      residencyLease?.close()
      residencyLease = nil
    }
  }
}

/// Deterministic codec for the resolved-specification sidecar file.
enum MLXSpecificationArchive {
  static let maximumArchiveBytes = 1 * 1_024 * 1_024
  static let maximumEntries = 256

  struct Entry: Codable {
    let model: MLXModel
    let specification: MLXModelSpecification
  }

  static func save(_ entries: [Entry], to url: URL) throws {
    guard entries.count <= maximumEntries else { throw MLXTextPersistenceError.oversized }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(
        entries.sorted {
          if $0.model.repositoryID == $1.model.repositoryID {
            if $0.model.revision == $1.model.revision {
              return Self.sortKey($0.model).utf8.lexicographicallyPrecedes(
                Self.sortKey($1.model).utf8)
            }
            return $0.model.revision.utf8.lexicographicallyPrecedes($1.model.revision.utf8)
          }
          return $0.model.repositoryID.utf8.lexicographicallyPrecedes($1.model.repositoryID.utf8)
        })
      guard data.count <= maximumArchiveBytes else { throw MLXTextPersistenceError.oversized }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch let error as MLXTextPersistenceError {
      throw error
    } catch {
      throw MLXTextPersistenceError.writeFailed
    }
  }

  private static func sortKey(_ model: MLXModel) -> String {
    "\(model.extraEOSTokens.sorted().joined(separator: ","))|\(model.disablesThinking)|\(model.sampling.temperature)|\(model.sampling.topP)|\(model.sampling.topK)|\(model.sampling.repetitionPenalty)"
  }

  static func load(from url: URL) throws -> [Entry] {
    let data: Data
    do { data = try Data(contentsOf: url) } catch { throw MLXTextPersistenceError.unreadable }
    guard data.count <= Self.maximumArchiveBytes else { throw MLXTextPersistenceError.oversized }
    let entries: [Entry]
    do { entries = try JSONDecoder().decode([Entry].self, from: data) } catch {
      throw MLXTextPersistenceError.malformed
    }
    guard entries.count <= Self.maximumEntries else { throw MLXTextPersistenceError.oversized }
    var models = Set<MLXModel>()
    for entry in entries {
      guard models.insert(entry.model).inserted else {
        throw MLXTextPersistenceError.duplicateModel
      }
      let specification = entry.specification
      guard specification.model == entry.model,
        specification.repositoryID == entry.model.repositoryID,
        specification.revision == entry.model.revision,
        specification.extraEOSTokens == entry.model.extraEOSTokens,
        specification.disablesThinking == entry.model.disablesThinking,
        specification.sampling == entry.model.sampling
      else { throw MLXTextPersistenceError.invalidEntry }
      do { try specification.manifest.validate() } catch {
        throw MLXTextPersistenceError.invalidEntry
      }
    }
    return entries
  }
}

/// Stable, bounded failures for the resolved-specification sidecar.
///
/// Hosts can classify these errors without matching Foundation descriptions.
public enum MLXTextPersistenceError: Error, Equatable, Sendable {
  case unreadable
  case malformed
  case oversized
  case duplicateModel
  case invalidEntry
  case writeFailed
}
