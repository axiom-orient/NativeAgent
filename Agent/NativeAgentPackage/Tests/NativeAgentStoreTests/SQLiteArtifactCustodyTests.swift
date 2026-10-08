import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentStore

private func makeArtifactCustodyRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "sqlite-artifact-custody-\(UUID())", isDirectory: true
  )
}

private func commitArtifact(
  _ artifact: ArtifactRecord,
  from snapshot: SessionSnapshot,
  to store: ApplicationSupportSessionStore
) async throws -> SessionSnapshot {
  let updated = snapshot.applying(
    .appended(messages: [], artifacts: [artifact], updatedAt: snapshot.updatedAt)
  )
  try await store.commit(
    SessionPersistenceTransaction(
      snapshot: updated,
      delta: SessionPersistenceDelta(
        expectedRevision: snapshot.revision,
        artifacts: .append(startingAt: 0, artifacts: [artifact])
      )
    )
  )
  return updated
}

private func attemptArtifactWrite(
  to store: ApplicationSupportSessionStore,
  snapshot: SessionSnapshot,
  bytes: Data
) async -> Result<ArtifactRecord, any Error> {
  do {
    return .success(
      try await store.persistArtifact(
        sessionID: snapshot.sessionID,
        artifact: ArtifactWriteRequest(
          preferredFilename: "evidence.txt", mimeType: "text/plain", data: bytes
        ),
        createdAt: snapshot.createdAt
      )
    )
  } catch {
    return .failure(error)
  }
}

@Test
func sqlitePreparationPreservesStagedArtifactUntilCommit() async throws {
  let root = makeArtifactCustodyRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = ApplicationSupportSessionStore(rootURL: root)
  let snapshot = SessionSnapshot(sessionID: "staged-artifact")
  try await writer.createSession(snapshot, events: [], effects: [])
  let bytes = Data("still awaiting metadata commit".utf8)
  let artifact = try await writer.persistArtifact(
    sessionID: snapshot.sessionID,
    artifact: ArtifactWriteRequest(
      preferredFilename: "evidence.txt", mimeType: "text/plain", data: bytes
    ),
    createdAt: snapshot.createdAt
  )

  // A separate reader prepares while the writer owns uncommitted payload bytes.
  let reader = ApplicationSupportSessionStore(rootURL: root)
  let beforeCommit = try #require(try await reader.loadSnapshot(sessionID: snapshot.sessionID))
  #expect(beforeCommit.artifacts.isEmpty)
  let artifactURL = root.appendingPathComponent(artifact.relativePath)
  #expect(try Data(contentsOf: artifactURL) == bytes)

  let committed = try await commitArtifact(artifact, from: snapshot, to: writer)
  #expect(try await reader.loadSnapshot(sessionID: snapshot.sessionID) == committed)
  #expect(try await reader.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifact.id) == bytes)
}

@Test
func sqlitePreparationAndStaleDiscardPreserveCommittedArtifact() async throws {
  let root = makeArtifactCustodyRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = ApplicationSupportSessionStore(rootURL: root)
  let snapshot = SessionSnapshot(sessionID: "committed-artifact")
  try await writer.createSession(snapshot, events: [], effects: [])
  let staleReader = ApplicationSupportSessionStore(rootURL: root)
  #expect(try await staleReader.loadSnapshot(sessionID: snapshot.sessionID)?.artifacts.isEmpty == true)

  let bytes = Data("committed evidence".utf8)
  let artifact = try await writer.persistArtifact(
    sessionID: snapshot.sessionID,
    artifact: ArtifactWriteRequest(
      preferredFilename: "evidence.txt", mimeType: "text/plain", data: bytes
    ),
    createdAt: snapshot.createdAt
  )
  let committed = try await commitArtifact(artifact, from: snapshot, to: writer)

  // The old reader's view predates this commit; an explicit discard must use
  // the current durable reference, and a new bootstrap must retain the bytes.
  try await staleReader.discardUnreferencedArtifact(artifact)
  let reopened = ApplicationSupportSessionStore(rootURL: root)
  try await reopened.prepare()
  #expect(try await reopened.loadSnapshot(sessionID: snapshot.sessionID) == committed)
  #expect(try await reopened.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifact.id) == bytes)
}

@Test
func sqliteArtifactFilenameCollisionPreservesOtherStoreCommittedBytes() async throws {
  let root = makeArtifactCustodyRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = ApplicationSupportSessionStore(
    rootURL: root, artifactIDGenerator: { "shared-artifact-id" }
  )
  let snapshot = SessionSnapshot(sessionID: "filename-collision")
  try await writer.createSession(snapshot, events: [], effects: [])
  let staleWriter = ApplicationSupportSessionStore(
    rootURL: root, artifactIDGenerator: { "shared-artifact-id" }
  )

  // Prime the independent instance's issued-ID cache before the other commit.
  let discarded = try await staleWriter.persistArtifact(
    sessionID: snapshot.sessionID,
    artifact: ArtifactWriteRequest(
      preferredFilename: "discarded.txt", mimeType: "text/plain", data: Data("temporary".utf8)
    ),
    createdAt: snapshot.createdAt
  )
  try await staleWriter.discardUnreferencedArtifact(discarded)

  let bytes = Data("original committed bytes".utf8)
  let artifact = try await writer.persistArtifact(
    sessionID: snapshot.sessionID,
    artifact: ArtifactWriteRequest(
      preferredFilename: "evidence.txt", mimeType: "text/plain", data: bytes
    ),
    createdAt: snapshot.createdAt
  )
  let committed = try await commitArtifact(artifact, from: snapshot, to: writer)

  await #expect(throws: AgentError.self) {
    _ = try await staleWriter.persistArtifact(
      sessionID: snapshot.sessionID,
      artifact: ArtifactWriteRequest(
        preferredFilename: "evidence.txt", mimeType: "text/plain", data: Data("replacement".utf8)
      ),
      createdAt: snapshot.createdAt
    )
  }
  #expect(try Data(contentsOf: root.appendingPathComponent(artifact.relativePath)) == bytes)
  #expect(try await staleWriter.loadSnapshot(sessionID: snapshot.sessionID) == committed)
  #expect(try await staleWriter.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifact.id) == bytes)
}

@Test
func sqliteConcurrentArtifactFilenameCollisionHasOnePreservedWriter() async throws {
  let root = makeArtifactCustodyRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let first = ApplicationSupportSessionStore(
    rootURL: root, artifactIDGenerator: { "shared-artifact-id" }
  )
  let second = ApplicationSupportSessionStore(
    rootURL: root, artifactIDGenerator: { "shared-artifact-id" }
  )
  let snapshot = SessionSnapshot(sessionID: "concurrent-filename-collision")
  try await first.createSession(snapshot, events: [], effects: [])
  try await second.prepare()
  let firstBytes = Data(repeating: 0x41, count: 65_536)
  let secondBytes = Data(repeating: 0x42, count: 65_536)

  async let firstWrite = attemptArtifactWrite(to: first, snapshot: snapshot, bytes: firstBytes)
  async let secondWrite = attemptArtifactWrite(to: second, snapshot: snapshot, bytes: secondBytes)
  let outcomes = await (firstWrite, secondWrite)
  let artifact: ArtifactRecord
  let bytes: Data
  let writer: ApplicationSupportSessionStore
  switch outcomes {
  case (.success(let record), .failure(let error)):
    #expect(error is AgentError)
    artifact = record
    bytes = firstBytes
    writer = first
  case (.failure(let error), .success(let record)):
    #expect(error is AgentError)
    artifact = record
    bytes = secondBytes
    writer = second
  default:
    Issue.record("Expected exactly one artifact writer to own the colliding path: \(outcomes)")
    return
  }

  #expect(try Data(contentsOf: root.appendingPathComponent(artifact.relativePath)) == bytes)
  let committed = try await commitArtifact(artifact, from: snapshot, to: writer)
  #expect(try await second.loadSnapshot(sessionID: snapshot.sessionID) == committed)
  #expect(try await first.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifact.id) == bytes)
  #expect(try await second.loadArtifact(sessionID: snapshot.sessionID, artifactID: artifact.id) == bytes)
}
