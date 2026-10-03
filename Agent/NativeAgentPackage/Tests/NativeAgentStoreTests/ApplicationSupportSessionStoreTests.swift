import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentStore

private actor RecordingSharedClaimStore: SessionExecutionClaimStore {
  private var ownedClaim: SessionExecutionClaim?

  func acquireExecutionClaim(sessionID: String) throws -> SessionExecutionClaim {
    guard ownedClaim == nil else { throw AgentError.sessionBusy(sessionID) }
    let claim = SessionExecutionClaim(sessionID: sessionID, claimID: "shared-claim")
    ownedClaim = claim
    return claim
  }

  func releaseExecutionClaim(_ claim: SessionExecutionClaim) throws {
    guard ownedClaim == claim else {
      throw AgentError.persistenceFailure("Shared claim is not owned.")
    }
    ownedClaim = nil
  }

  func ownsClaim() -> Bool { ownedClaim != nil }
}

@Test
func publicApplicationSupportStoreUsesExplicitSharedClaimOwnership() async throws {
  let root = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let claims = RecordingSharedClaimStore()
  let store = ApplicationSupportSessionStore(
    rootURL: root,
    sharedExecutionClaimStore: claims
  )

  let claim = try await store.acquireExecutionClaim(sessionID: "shared-session")
  #expect(await claims.ownsClaim())
  try await store.releaseExecutionClaim(claim)
  #expect(await claims.ownsClaim() == false)
}

@Test
func fileExecutionClaimsExcludeIndependentStoreInstancesAndReleaseCleanly() async throws {
  let root = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let first = ApplicationSupportFileExecutionClaimStore(rootURL: root)
  let second = ApplicationSupportFileExecutionClaimStore(rootURL: root)

  let claim = try await first.acquireExecutionClaim(sessionID: "cross-process-session")
  await #expect(throws: AgentError.self) {
    _ = try await second.acquireExecutionClaim(sessionID: "cross-process-session")
  }
  try await first.releaseExecutionClaim(claim)

  let next = try await second.acquireExecutionClaim(sessionID: "cross-process-session")
  try await second.releaseExecutionClaim(next)
}

@Test
func sessionSnapshotDecodeRejectsContradictoryWaitState() throws {
  let valid = SessionSnapshot(
    sessionID: "invalid-wait-state",
    status: .waiting,
    waitState: .signal(identifier: "signal")
  )
  let encoded = try JSONEncoder().encode(valid)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["status"] = SessionStatus.running.rawValue
  let malformed = try JSONSerialization.data(withJSONObject: object)

  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(SessionSnapshot.self, from: malformed)
  }
}

@Test
func sessionWaitStateDecodeRejectsTimeWaitWithoutDeadline() throws {
  let valid = SessionWaitState.time(
    identifier: "timer",
    resumeAt: Date(timeIntervalSinceReferenceDate: 100)
  )
  let encoded = try JSONEncoder().encode(valid)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "resumeAt")
  let malformed = try JSONSerialization.data(withJSONObject: object)

  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(SessionWaitState.self, from: malformed)
  }
}

private func makeStoreTempRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
}

@Test
func createSessionCreatesSQLiteStateAndArtifactDirectory() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "session-1")
  try await store.createSession(snapshot, events: [], effects: [])

  let layout = StoreLayout(rootURL: tempRoot)
  #expect(FileManager.default.fileExists(atPath: layout.databaseURL.path))
  #expect(
    FileManager.default.fileExists(
      atPath: layout.artifactsDirectoryURL(sessionID: "session-1").path))
}

@Test
func artifactRoundTrip() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "session-1")
  try await store.createSession(snapshot, events: [], effects: [])

  let artifact = try await store.persistArtifact(
    sessionID: "session-1",
    artifact: ArtifactWriteRequest(
      preferredFilename: "a.txt",
      mimeType: "text/plain",
      data: Data("hello".utf8)
    ),
    createdAt: Date()
  )

  let updated = snapshot.applying(
    .appended(
      messages: [],
      artifacts: snapshot.artifacts + [artifact],
      updatedAt: snapshot.updatedAt
    ))
  try await store.commit(
    SessionPersistenceTransaction(
      snapshot: updated,
      delta: SessionPersistenceDelta(
        expectedRevision: snapshot.revision,
        artifacts: .append(startingAt: 0, artifacts: [artifact])
      )
    )
  )

  let data = try await store.loadArtifact(sessionID: "session-1", artifactID: artifact.id)
  #expect(String(decoding: data, as: UTF8.self) == "hello")
}

@Test
func sqliteStoreRejectsSameSizeArtifactTamperingBeforeMetadataCommit() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "tampered-artifact-session")
  try await store.createSession(snapshot, events: [], effects: [])
  let record = try await store.persistArtifact(
    sessionID: snapshot.sessionID,
    artifact: ArtifactWriteRequest(
      preferredFilename: "evidence.txt",
      mimeType: "text/plain",
      data: Data("original".utf8)
    ),
    createdAt: Date(timeIntervalSince1970: 1)
  )
  let artifactURL = StoreLayout(rootURL: tempRoot)
    .artifactsDirectoryURL(sessionID: snapshot.sessionID)
    .appendingPathComponent(record.filename, isDirectory: false)
  try Data("tampered".utf8).write(to: artifactURL, options: .atomic)

  let updated = snapshot.applying(
    .appended(
      messages: [],
      artifacts: [record],
      updatedAt: Date(timeIntervalSince1970: 2)
    )
  )
  await #expect(throws: AgentError.self) {
    try await store.commit(
      SessionPersistenceTransaction(
        snapshot: updated,
        delta: SessionPersistenceDelta(
          expectedRevision: snapshot.revision,
          artifacts: .append(startingAt: 0, artifacts: [record])
        )
      )
    )
  }

  let persisted = try #require(
    try await store.loadSnapshot(sessionID: snapshot.sessionID)
  )
  #expect(persisted.revision == snapshot.revision)
  #expect(persisted.artifacts.isEmpty)
}

@Test
func sqliteStoreRejectsSameSizeArtifactTamperingOnLoad() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "tampered-artifact-load")
  try await store.createSession(snapshot, events: [], effects: [])
  let record = try await store.persistArtifact(
    sessionID: snapshot.sessionID,
    artifact: ArtifactWriteRequest(
      preferredFilename: "evidence.txt",
      mimeType: "text/plain",
      data: Data("original".utf8)
    ),
    createdAt: Date(timeIntervalSince1970: 1)
  )
  let updated = snapshot.applying(
    .appended(
      messages: [],
      artifacts: [record],
      updatedAt: Date(timeIntervalSince1970: 2)
    )
  )
  try await store.commit(
    SessionPersistenceTransaction(
      snapshot: updated,
      delta: SessionPersistenceDelta(
        expectedRevision: snapshot.revision,
        artifacts: .append(startingAt: 0, artifacts: [record])
      )
    )
  )

  let artifactURL = StoreLayout(rootURL: tempRoot)
    .artifactsDirectoryURL(sessionID: snapshot.sessionID)
    .appendingPathComponent(record.filename, isDirectory: false)
  try Data("tampered".utf8).write(to: artifactURL, options: .atomic)

  await #expect(throws: AgentError.self) {
    _ = try await store.loadArtifact(
      sessionID: snapshot.sessionID,
      artifactID: record.id
    )
  }
}

@Test
func sqliteAtomicForkRollsBackSourceWhenTargetPayloadFails() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let timestamp = Date(timeIntervalSince1970: 10)
  let source = SessionSnapshot(
    sessionID: "atomic-fork-source",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  try await store.createSession(source, events: [], effects: [])

  let reduction = try SessionReducer.reduce(
    .recordCommand(
      ["fork": .string("atomic-fork-target")],
      updatedAt: Date(timeIntervalSince1970: 11)
    ),
    state: source
  )
  let delta = try #require(reduction.persistenceDelta)
  let target = SessionSnapshot(
    sessionID: "atomic-fork-target",
    createdAt: Date(timeIntervalSince1970: 11),
    updatedAt: Date(timeIntervalSince1970: 11)
  )
  let invalidTargetEffect = EffectRecord(
    sessionID: target.sessionID,
    scope: .toolCall,
    key: "invalid-target-effect",
    effectType: "test",
    status: .completed,
    createdAt: timestamp,
    updatedAt: timestamp,
    input: .object([:]),
    result: nil
  )

  await #expect(throws: AgentError.self) {
    try await store.commitFork(
      SessionForkPersistenceTransaction(
        source: SessionPersistenceTransaction(
          snapshot: reduction.snapshot,
          delta: delta
        ),
        target: target,
        targetEffects: [invalidTargetEffect]
      )
    )
  }

  #expect(try await store.loadSnapshot(sessionID: source.sessionID) == source)
  #expect(try await store.loadSnapshot(sessionID: target.sessionID) == nil)
}

@Test
func sqliteRejectsUnsupportedDurableSessionAndEventSchemas() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let timestamp = Date(timeIntervalSince1970: 19)
  let unsupportedSnapshot = SessionSnapshot(
    schemaVersion: "native-agent.session.v2",
    sessionID: "unsupported-session-schema",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  await #expect(throws: AgentError.self) {
    try await store.createSession(unsupportedSnapshot, events: [], effects: [])
  }
  #expect(
    try await store.loadSnapshot(sessionID: unsupportedSnapshot.sessionID) == nil
  )

  let candidate = SessionSnapshot(
    sessionID: "unsupported-event-schema",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  let unsupportedEvent = SessionEvent(
    schemaVersion: "native-agent.event.v2",
    sessionID: candidate.sessionID,
    kind: .sessionCreated,
    createdAt: timestamp
  )
  await #expect(throws: AgentError.self) {
    try await store.createSession(
      candidate,
      events: [unsupportedEvent],
      effects: []
    )
  }
  #expect(try await store.loadSnapshot(sessionID: candidate.sessionID) == nil)
}

@Test
func sqliteRuntimeAdmissionReadsBoundedHeaderBeforeHydration() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let timestamp = Date(timeIntervalSince1970: 19.5)
  let snapshot = SessionSnapshot(
    sessionID: "runtime-admission",
    createdAt: timestamp,
    updatedAt: timestamp,
    messages: [
      AgentMessage(id: "m1", role: .user, content: "hello", createdAt: timestamp),
      AgentMessage(id: "m2", role: .assistant, content: "world", createdAt: timestamp),
    ]
  )
  try await store.createSession(snapshot, events: [], effects: [])

  let admission = try #require(
    try await store.loadSessionRuntimeAdmission(sessionID: snapshot.sessionID)
  )
  #expect(admission.schemaVersion == SessionSnapshot.currentSchemaVersion)
  #expect(admission.revision == snapshot.revision)
  #expect(admission.messageCount == 2)
  #expect(admission.hydrationPayloadBytes > 0)
  #expect(admission.artifactCount == 0)
}

@Test
func sqliteTransactionsRejectCrossSessionEventsAndEffectsBeforePublishing() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let timestamp = Date(timeIntervalSince1970: 20)
  let unrelated = SessionSnapshot(
    sessionID: "transaction-owner-unrelated",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  try await store.createSession(unrelated, events: [], effects: [])

  let candidate = SessionSnapshot(
    sessionID: "transaction-owner-candidate",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  let wrongEvent = SessionEvent(
    sessionID: unrelated.sessionID,
    kind: .snapshotSaved,
    createdAt: timestamp
  )
  let wrongEffect = EffectRecord(
    sessionID: unrelated.sessionID,
    scope: .toolCall,
    key: "cross-session-effect",
    effectType: "test",
    status: .completed,
    createdAt: timestamp,
    updatedAt: timestamp,
    input: .object([:]),
    result: .object(["ok": .bool(true)])
  )

  await #expect(throws: AgentError.self) {
    try await store.createSession(
      candidate,
      events: [wrongEvent],
      effects: []
    )
  }
  await #expect(throws: AgentError.self) {
    try await store.createSession(
      candidate,
      events: [],
      effects: [wrongEffect]
    )
  }
  #expect(try await store.loadSnapshot(sessionID: candidate.sessionID) == nil)

  try await store.createSession(candidate, events: [], effects: [])
  let reduction = try SessionReducer.reduce(
    .recordCommand(
      ["operation": .string("ownership-check")],
      updatedAt: Date(timeIntervalSince1970: 21)
    ),
    state: candidate
  )
  let delta = try #require(reduction.persistenceDelta)

  await #expect(throws: AgentError.self) {
    try await store.commit(
      SessionPersistenceTransaction(
        snapshot: reduction.snapshot,
        delta: delta,
        events: [wrongEvent]
      )
    )
  }
  await #expect(throws: AgentError.self) {
    try await store.commit(
      SessionPersistenceTransaction(
        snapshot: reduction.snapshot,
        delta: delta,
        effects: [wrongEffect]
      )
    )
  }

  #expect(try await store.loadSnapshot(sessionID: candidate.sessionID) == candidate)
  #expect(try await store.loadSnapshot(sessionID: unrelated.sessionID) == unrelated)
  #expect(try await store.loadEvents(sessionID: unrelated.sessionID).isEmpty)
  #expect(
    try await store.loadEffect(
      sessionID: unrelated.sessionID,
      scope: wrongEffect.scope,
      key: wrongEffect.key
    ) == nil
  )
}

@Test
func sqliteAtomicForkRejectsCrossSessionTargetRecordsBeforeMutation() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let timestamp = Date(timeIntervalSince1970: 30)
  let source = SessionSnapshot(
    sessionID: "fork-owner-source",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  let unrelated = SessionSnapshot(
    sessionID: "fork-owner-unrelated",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  try await store.createSession(source, events: [], effects: [])
  try await store.createSession(unrelated, events: [], effects: [])

  let reduction = try SessionReducer.reduce(
    .recordCommand(
      ["fork": .string("fork-owner-target")],
      updatedAt: Date(timeIntervalSince1970: 31)
    ),
    state: source
  )
  let delta = try #require(reduction.persistenceDelta)
  let target = SessionSnapshot(
    sessionID: "fork-owner-target",
    createdAt: Date(timeIntervalSince1970: 31),
    updatedAt: Date(timeIntervalSince1970: 31)
  )
  let wrongEvent = SessionEvent(
    sessionID: unrelated.sessionID,
    kind: .sessionCreated,
    createdAt: timestamp
  )
  let wrongEffect = EffectRecord(
    sessionID: unrelated.sessionID,
    scope: .toolCall,
    key: "cross-session-fork-effect",
    effectType: "test",
    status: .completed,
    createdAt: timestamp,
    updatedAt: timestamp,
    input: .object([:]),
    result: .object(["ok": .bool(true)])
  )
  let sourceTransaction = SessionPersistenceTransaction(
    snapshot: reduction.snapshot,
    delta: delta
  )

  await #expect(throws: AgentError.self) {
    try await store.commitFork(
      SessionForkPersistenceTransaction(
        source: sourceTransaction,
        target: target,
        targetEvents: [wrongEvent]
      )
    )
  }
  await #expect(throws: AgentError.self) {
    try await store.commitFork(
      SessionForkPersistenceTransaction(
        source: sourceTransaction,
        target: target,
        targetEffects: [wrongEffect]
      )
    )
  }

  #expect(try await store.loadSnapshot(sessionID: source.sessionID) == source)
  #expect(try await store.loadSnapshot(sessionID: unrelated.sessionID) == unrelated)
  #expect(try await store.loadSnapshot(sessionID: target.sessionID) == nil)
  #expect(
    FileManager.default.fileExists(
      atPath: StoreLayout(rootURL: tempRoot)
        .sessionRootURL(sessionID: target.sessionID)
        .path
    ) == false
  )
}

@Test
func applicationSupportSessionStorePersistsEffectLedgerRecords() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "session-1")
  try await store.createSession(snapshot, events: [], effects: [])

  let record = EffectRecord(
    sessionID: snapshot.sessionID,
    scope: .toolCall,
    key: #"files.writeText:{"path":"note.txt"}"#,
    effectType: "files.writeText",
    status: .completed,
    createdAt: Date(timeIntervalSince1970: 10),
    updatedAt: Date(timeIntervalSince1970: 11),
    input: .object(["path": .string("note.txt")]),
    result: .object(["ok": .bool(true)])
  )

  try await store.saveEffect(record)
  let loaded = try await store.loadEffect(
    sessionID: snapshot.sessionID, scope: .toolCall, key: record.key)
  #expect(loaded == record)

}

@Test
func sqliteEffectReceiptsCannotLoseCertaintyOrChangeIdentity() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "effect-monotonic-session")
  try await store.createSession(snapshot, events: [], effects: [])

  let createdAt = Date(timeIntervalSince1970: 10)
  let input: JSONValue = .object(["path": .string("note.txt")])
  let started = EffectRecord(
    sessionID: snapshot.sessionID,
    scope: .toolCall,
    key: "write-note",
    effectType: "files.writeText",
    status: .started,
    createdAt: createdAt,
    updatedAt: createdAt,
    input: input
  )
  try await store.saveEffect(started)

  let completed = EffectRecord(
    sessionID: started.sessionID,
    scope: started.scope,
    key: started.key,
    effectType: started.effectType,
    status: .completed,
    createdAt: started.createdAt,
    updatedAt: Date(timeIntervalSince1970: 11),
    input: started.input,
    result: .object(["ok": .bool(true)])
  )
  try await store.saveEffect(completed)

  await #expect(throws: AgentError.self) {
    try await store.saveEffect(started)
  }
  await #expect(throws: AgentError.self) {
    try await store.saveEffect(
      EffectRecord(
        sessionID: completed.sessionID,
        scope: completed.scope,
        key: completed.key,
        effectType: "files.delete",
        status: .completed,
        createdAt: completed.createdAt,
        updatedAt: Date(timeIntervalSince1970: 12),
        input: completed.input,
        result: .object(["ok": .bool(true)])
      )
    )
  }

  let persisted = try await store.loadEffect(
    sessionID: completed.sessionID,
    scope: completed.scope,
    key: completed.key
  )
  #expect(persisted == completed)
}

@Test
func sqliteFailedEffectCanBeReconciledOnceToVerifiedCompletion() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "effect-reconciliation-session")
  try await store.createSession(snapshot, events: [], effects: [])

  let failed = EffectRecord(
    sessionID: snapshot.sessionID,
    scope: .toolCall,
    key: "write-note",
    effectType: "files.writeText",
    status: .failed,
    createdAt: Date(timeIntervalSince1970: 10),
    updatedAt: Date(timeIntervalSince1970: 11),
    input: .object(["path": .string("note.txt")]),
    error: "outcome unknown"
  )
  try await store.saveEffect(failed)

  let completed = EffectRecord(
    sessionID: failed.sessionID,
    scope: failed.scope,
    key: failed.key,
    effectType: failed.effectType,
    status: .completed,
    createdAt: failed.createdAt,
    updatedAt: Date(timeIntervalSince1970: 12),
    input: failed.input,
    result: .object(["ok": .bool(true)]),
    metadata: ["reconciled": .bool(true)]
  )
  try await store.saveEffect(completed)

  await #expect(throws: AgentError.self) {
    try await store.saveEffect(
      EffectRecord(
        sessionID: completed.sessionID,
        scope: completed.scope,
        key: completed.key,
        effectType: completed.effectType,
        status: .completed,
        createdAt: completed.createdAt,
        updatedAt: Date(timeIntervalSince1970: 13),
        input: completed.input,
        result: .object(["ok": .bool(false)])
      )
    )
  }
  #expect(
    try await store.loadEffect(
      sessionID: completed.sessionID,
      scope: completed.scope,
      key: completed.key
    ) == completed
  )
}

@Test
func sqliteStoreRejectsOrphanEffectRecords() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let record = EffectRecord(
    sessionID: "missing-session",
    scope: .toolCall,
    key: "orphan-effect",
    effectType: "test",
    status: .completed,
    createdAt: Date(timeIntervalSince1970: 10),
    updatedAt: Date(timeIntervalSince1970: 11),
    input: .object([:]),
    result: .object([:])
  )

  await #expect(throws: AgentError.self) {
    try await store.saveEffect(record)
  }
}

@Test
func sqliteStoreReadsSessionHeadersAndTranscriptPagesWithoutFullListMaterialization() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let messages = (0..<5).map { index in
    AgentMessage(id: "m\(index)", role: .user, content: "message \(index)")
  }
  try await store.createSession(
    SessionSnapshot(
      sessionID: "older",
      title: "Older",
      updatedAt: Date(timeIntervalSince1970: 1)
    ),
    events: [],
    effects: []
  )
  try await store.createSession(
    SessionSnapshot(
      sessionID: "newer",
      title: "Newer",
      updatedAt: Date(timeIntervalSince1970: 2),
      messages: messages
    ),
    events: [],
    effects: []
  )

  let summaries = try await store.listSessionSummaries(limit: 1, offset: 0)
  #expect(summaries.map(\.sessionID) == ["newer"])
  #expect(summaries.first?.messageCount == 5)

  let page = try await store.loadSessionMessages(
    sessionID: "newer",
    offset: 1,
    limit: 2
  )
  #expect(page.messages.map(\.id) == ["m1", "m2"])
  #expect(page.totalCount == 5)
  #expect(page.nextOffset == 3)

  await #expect(throws: AgentError.self) {
    _ = try await store.listSessionSummaries(
      limit: SessionReadLimits.maximumPageSize + 1,
      offset: 0
    )
  }
}

@Test
func sqliteTransactionRejectsHeaderCountsThatDoNotMatchUnchangedRows() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()
  let original = SessionSnapshot(sessionID: "count-integrity")
  try await store.createSession(original, events: [], effects: [])

  let invalid = SessionSnapshot(
    revision: 1,
    sessionID: original.sessionID,
    createdAt: original.createdAt,
    updatedAt: original.updatedAt,
    messages: [AgentMessage(id: "injected", role: .user, content: "not in delta")]
  )
  await #expect(throws: AgentError.self) {
    try await store.commit(
      SessionPersistenceTransaction(
        snapshot: invalid,
        delta: SessionPersistenceDelta(expectedRevision: 0)
      )
    )
  }
  #expect(try await store.loadSnapshot(sessionID: original.sessionID) == original)
}

@Test
func invalidSessionIDsAreRejectedAcrossPublicEntryPoints() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let invalidSessionIDs = ["../evil", "a/../../b", "has space", "line\nbreak"]

  for sessionID in invalidSessionIDs {
    await #expect(throws: AgentError.self) {
      try await store.createSession(SessionSnapshot(sessionID: sessionID), events: [], effects: [])
    }
    await #expect(throws: AgentError.self) {
      _ = try await store.loadSnapshot(sessionID: sessionID)
    }
    await #expect(throws: AgentError.self) {
      _ = try await store.sessionDirectoryURL(sessionID: sessionID)
    }
    await #expect(throws: AgentError.self) {
      _ = try await store.persistArtifact(
        sessionID: sessionID,
        artifact: ArtifactWriteRequest(
          preferredFilename: "bad.txt",
          mimeType: "text/plain",
          data: Data("x".utf8)
        ),
        createdAt: Date()
      )
    }
  }
}

@Test
func createSessionRejectsInvalidSessionID() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  await #expect(throws: AgentError.self) {
    try await store.createSession(SessionSnapshot(sessionID: "../evil"), events: [], effects: [])
  }
}

@Test
func persistArtifactSanitizesFilenameThroughStoragePlan() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "session-1")
  try await store.createSession(snapshot, events: [], effects: [])

  let artifact = try await store.persistArtifact(
    sessionID: "session-1",
    artifact: ArtifactWriteRequest(
      preferredFilename: " :bad/name\\\\.txt ",
      mimeType: "text/plain",
      data: Data("hello".utf8)
    ),
    createdAt: Date()
  )

  #expect(artifact.filename.hasSuffix("_bad_name__.txt"))
  #expect(artifact.relativePath.contains("/artifacts/\(artifact.filename)"))
}

@Test
func persistArtifactUsesInjectedArtifactIDGenerator() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(
    rootURL: tempRoot,
    artifactIDGenerator: { "artifact-fixed" }
  )
  try await store.prepare()

  let snapshot = SessionSnapshot(sessionID: "session-1")
  try await store.createSession(snapshot, events: [], effects: [])

  let artifact = try await store.persistArtifact(
    sessionID: "session-1",
    artifact: ArtifactWriteRequest(
      preferredFilename: "note.txt",
      mimeType: "text/plain",
      data: Data("hello".utf8)
    ),
    createdAt: Date(timeIntervalSince1970: 123)
  )

  #expect(artifact.id == "artifact-fixed")
  #expect(artifact.filename == "artifact-fixed-note.txt")
  #expect(artifact.relativePath == "sessions/session-1/artifacts/artifact-fixed-note.txt")
}

@Test
func persistArtifactValidationFailureLeavesNoDirectorySideEffect() async throws {
  let tempRoot = makeStoreTempRoot()
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  await #expect(throws: AgentError.self) {
    _ = try await store.persistArtifact(
      sessionID: "../evil",
      artifact: ArtifactWriteRequest(
        preferredFilename: "bad.txt",
        mimeType: "text/plain",
        data: Data("x".utf8)
      ),
      createdAt: Date()
    )
  }

  let sessionsRoot = StoreLayout(rootURL: tempRoot).sessionsRootURL
  let contents = try FileManager.default.contentsOfDirectory(
    at: sessionsRoot, includingPropertiesForKeys: nil)
  #expect(contents.isEmpty)
}

@Test
func querySessionListFiltersIDsDatesKeywordsAndLimitWithBoundedPreview() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  try await store.createSession(
    SessionSnapshot(
      sessionID: "alpha",
      title: "Alpha",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 30),
      messages: [
        AgentMessage(
          id: "alpha-user",
          role: .user,
          content: "needle literal %_ token",
          createdAt: Date(timeIntervalSince1970: 10)
        ),
        AgentMessage(
          id: "alpha-assistant",
          role: .assistant,
          content: "assistant preview",
          createdAt: Date(timeIntervalSince1970: 11)
        ),
      ],
      metadata: ["uihost.source": .string("shortcut")]
    ), events: [], effects: [])
  try await store.createSession(
    SessionSnapshot(
      sessionID: "beta",
      title: "Beta",
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 20),
      messages: [
        AgentMessage(
          id: "beta-user",
          role: .user,
          content: "needle literal XX token",
          createdAt: Date(timeIntervalSince1970: 12)
        )
      ]
    ), events: [], effects: [])
  try await store.createSession(
    SessionSnapshot(
      sessionID: "gamma",
      title: "Gamma",
      createdAt: Date(timeIntervalSince1970: 3),
      updatedAt: Date(timeIntervalSince1970: 25),
      messages: [
        AgentMessage(
          id: "gamma-user",
          role: .user,
          content: "needle literal %_ token",
          createdAt: Date(timeIntervalSince1970: 13)
        )
      ]
    ), events: [], effects: [])

  let filtered = try await store.querySessionList(
    SessionListQuery(
      sessionIDs: ["alpha", "beta"],
      keywords: ["needle"],
      startDate: Date(timeIntervalSince1970: 15),
      endDate: Date(timeIntervalSince1970: 35),
      limit: 1
    )
  )
  #expect(filtered.map { $0.summary.sessionID } == ["alpha"])
  #expect(filtered.first?.preview == "assistant preview")
  #expect(filtered.first?.source == "shortcut")

  let secondPage = try await store.querySessionList(
    SessionListQuery(limit: 1, offset: 1)
  )
  #expect(secondPage.map { $0.summary.sessionID } == ["gamma"])

  let outOfRangePage = try await store.querySessionList(
    SessionListQuery(limit: 10, offset: 100)
  )
  #expect(outOfRangePage.isEmpty)

  await #expect(throws: AgentError.self) {
    _ = try await store.querySessionList(
      SessionListQuery(limit: 1, offset: -1)
    )
  }

  let literal = try await store.querySessionList(
    SessionListQuery(keywords: ["literal %_ token"], limit: 10)
  )
  #expect(literal.map { $0.summary.sessionID } == ["alpha", "gamma"])

  let whitespace = try await store.querySessionList(
    SessionListQuery(keywords: ["  ", "\n"], limit: 10)
  )
  #expect(whitespace.count == 3)
}

@Test
func searchSessionMessagesFiltersSessionDateKeywordAndPreservesMessageValues() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  try await store.createSession(
    SessionSnapshot(
      sessionID: "search-alpha",
      title: "Search Alpha",
      updatedAt: Date(timeIntervalSince1970: 40),
      messages: [
        AgentMessage(
          id: "old-user",
          role: .user,
          content: "target old",
          createdAt: Date(timeIntervalSince1970: 10)
        ),
        AgentMessage(
          id: "matching-assistant",
          role: .assistant,
          content: "target assistant",
          createdAt: Date(timeIntervalSince1970: 20)
        ),
      ]
    ), events: [], effects: [])
  try await store.createSession(
    SessionSnapshot(
      sessionID: "search-beta",
      title: "Search Beta",
      updatedAt: Date(timeIntervalSince1970: 50),
      messages: [
        AgentMessage(
          id: "newer-assistant",
          role: .assistant,
          content: "target newer",
          createdAt: Date(timeIntervalSince1970: 30)
        )
      ]
    ),
    events: [],
    effects: []
  )

  let matches = try await store.searchSessionMessages(
    SessionMessageSearchQuery(
      sessionIDs: ["search-alpha"],
      keywords: ["target"],
      startDate: Date(timeIntervalSince1970: 15),
      endDate: Date(timeIntervalSince1970: 25),
      limit: 10
    )
  )
  #expect(matches.totalCount == 1)
  #expect(matches.offset == 0)
  #expect(matches.matches.count == 1)
  #expect(matches.matches.first?.sessionID == "search-alpha")
  #expect(matches.matches.first?.sessionTitle == "Search Alpha")
  #expect(matches.matches.first?.message.id == "matching-assistant")
  #expect(matches.matches.first?.message.role == .assistant)
  #expect(matches.matches.first?.message.content == "target assistant")
  #expect(matches.matches.first?.message.createdAt == Date(timeIntervalSince1970: 20))
  #expect(matches.nextOffset == nil)

  let limited = try await store.searchSessionMessages(
    SessionMessageSearchQuery(keywords: ["target"], limit: 1)
  )
  #expect(limited.totalCount == 3)
  #expect(limited.offset == 0)
  #expect(limited.matches.map { $0.message.id } == ["newer-assistant"])
  #expect(limited.nextOffset == 1)

  let offsetPage = try await store.searchSessionMessages(
    SessionMessageSearchQuery(keywords: ["target"], limit: 1, offset: 1)
  )
  #expect(offsetPage.totalCount == 3)
  #expect(offsetPage.offset == 1)
  #expect(offsetPage.matches.map { $0.message.id } == ["matching-assistant"])
  #expect(offsetPage.nextOffset == 2)

  let emptyKeywordPage = try await store.searchSessionMessages(
    SessionMessageSearchQuery(
      sessionIDs: ["search-alpha"],
      startDate: Date(timeIntervalSince1970: 15),
      endDate: Date(timeIntervalSince1970: 25),
      limit: 10
    )
  )
  #expect(emptyKeywordPage.totalCount == 1)
  #expect(emptyKeywordPage.matches.map { $0.message.id } == ["matching-assistant"])

  let beyondEnd = try await store.searchSessionMessages(
    SessionMessageSearchQuery(keywords: ["target"], limit: 1, offset: 99)
  )
  #expect(beyondEnd.totalCount == 3)
  #expect(beyondEnd.offset == 99)
  #expect(beyondEnd.matches.isEmpty)
  #expect(beyondEnd.nextOffset == nil)
}

@Test
func sessionQueryValidatesBoundsAndIdentifiers() async throws {
  let tempRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let store = ApplicationSupportSessionStore(rootURL: tempRoot)
  try await store.prepare()

  await #expect(throws: AgentError.self) {
    _ = try await store.querySessionList(SessionListQuery(limit: 0))
  }
  await #expect(throws: AgentError.self) {
    _ = try await store.searchSessionMessages(
      SessionMessageSearchQuery(keywords: ["x"], limit: 1_001)
    )
  }
  await #expect(throws: AgentError.self) {
    _ = try await store.searchSessionMessages(
      SessionMessageSearchQuery(keywords: ["x"], offset: -1)
    )
  }
  await #expect(throws: AgentError.self) {
    _ = try await store.querySessionList(
      SessionListQuery(sessionIDs: ["bad/id"])
    )
  }
  await #expect(throws: AgentError.self) {
    _ = try await store.querySessionList(
      SessionListQuery(
        startDate: Date(timeIntervalSince1970: 2),
        endDate: Date(timeIntervalSince1970: 1)
      )
    )
  }
}

#if os(Linux)
  @Test
  func artifactLoadRejectsSymlinkedArtifactsDirectory() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    try await store.prepare()

    let snapshot = SessionSnapshot(sessionID: "session-1")
    try await store.createSession(snapshot, events: [], effects: [])

    let artifactsDirectory = StoreLayout(rootURL: tempRoot).artifactsDirectoryURL(
      sessionID: snapshot.sessionID)
    try fileManager.removeItem(at: artifactsDirectory)

    let outside = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    let linkedDirectory = outside.appendingPathComponent("redirected", isDirectory: true)
    try fileManager.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: artifactsDirectory, withDestinationURL: linkedDirectory)

    let artifactFile = linkedDirectory.appendingPathComponent("linked.txt")
    try Data("hello".utf8).write(to: artifactFile)

    let record = ArtifactRecord(
      id: "artifact-1",
      sessionID: snapshot.sessionID,
      filename: "linked.txt",
      relativePath: "sessions/\(snapshot.sessionID)/artifacts/linked.txt",
      mimeType: "text/plain",
      byteCount: 5,
      contentSHA256: SHA256HexDigest.digest(Data("hello".utf8)),
      createdAt: Date()
    )
    let snapshotWithArtifact = snapshot.applying(
      .appended(
        messages: [],
        artifacts: snapshot.artifacts + [record],
        updatedAt: record.createdAt
      ))

    await #expect(throws: AgentError.self) {
      try await store.commit(
        SessionPersistenceTransaction(
          snapshot: snapshotWithArtifact,
          delta: SessionPersistenceDelta(
            expectedRevision: snapshot.revision,
            artifacts: .append(startingAt: 0, artifacts: [record])
          )
        )
      )
    }
  }
#endif

@Test
func createSessionRejectsExistingSnapshotInsteadOfOverwritingIt() async throws {
  let root = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ApplicationSupportSessionStore(rootURL: root)
  try await store.prepare()

  let original = SessionSnapshot(
    sessionID: "duplicate-session",
    messages: [AgentMessage(role: .user, content: "original")]
  )
  try await store.createSession(original, events: [], effects: [])

  await #expect(throws: AgentError.self) {
    try await store.createSession(
      SessionSnapshot(
        sessionID: "duplicate-session",
        messages: [AgentMessage(role: .user, content: "replacement")]
      ),
      events: [],
      effects: []
    )
  }

  let reloaded = try #require(try await store.loadSnapshot(sessionID: "duplicate-session"))
  #expect(reloaded == original)
}

@Test
func persistArtifactRejectsInvalidAndDuplicateGeneratedIdentifiersBeforeWriting() async throws {
  let invalidRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: invalidRoot) }
  let invalidStore = ApplicationSupportSessionStore(
    rootURL: invalidRoot,
    artifactIDGenerator: { "../escape" }
  )
  try await invalidStore.prepare()
  try await invalidStore.createSession(
    SessionSnapshot(sessionID: "artifact-invalid-id"), events: [], effects: [])

  await #expect(throws: AgentError.self) {
    _ = try await invalidStore.persistArtifact(
      sessionID: "artifact-invalid-id",
      artifact: ArtifactWriteRequest(
        preferredFilename: "payload.txt",
        mimeType: "text/plain",
        data: Data("payload".utf8)
      ),
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
  let invalidNames = try FileManager.default.contentsOfDirectory(
    atPath: StoreLayout(rootURL: invalidRoot).artifactsDirectoryURL(
      sessionID: "artifact-invalid-id"
    ).path
  )
  #expect(invalidNames.isEmpty)

  let duplicateRoot = makeStoreTempRoot()
  defer { try? FileManager.default.removeItem(at: duplicateRoot) }
  let duplicateStore = ApplicationSupportSessionStore(
    rootURL: duplicateRoot,
    artifactIDGenerator: { "artifact-fixed" }
  )
  try await duplicateStore.prepare()
  try await duplicateStore.createSession(
    SessionSnapshot(sessionID: "artifact-duplicate-id"), events: [], effects: [])
  _ = try await duplicateStore.persistArtifact(
    sessionID: "artifact-duplicate-id",
    artifact: ArtifactWriteRequest(
      preferredFilename: "first.txt",
      mimeType: "text/plain",
      data: Data("first".utf8)
    ),
    createdAt: Date(timeIntervalSince1970: 1)
  )

  await #expect(throws: AgentError.self) {
    _ = try await duplicateStore.persistArtifact(
      sessionID: "artifact-duplicate-id",
      artifact: ArtifactWriteRequest(
        preferredFilename: "second.txt",
        mimeType: "text/plain",
        data: Data("second".utf8)
      ),
      createdAt: Date(timeIntervalSince1970: 2)
    )
  }
  let duplicateNames = try FileManager.default.contentsOfDirectory(
    atPath: StoreLayout(rootURL: duplicateRoot).artifactsDirectoryURL(
      sessionID: "artifact-duplicate-id"
    ).path
  )
  #expect(duplicateNames.count == 1)
}
