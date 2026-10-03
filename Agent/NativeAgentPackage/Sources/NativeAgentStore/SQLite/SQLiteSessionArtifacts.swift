import Foundation
import NativeAgentDomain

// Artifact custody shares the session-store authority; it is not another persistence owner.
extension SQLiteSessionStore {
  func persistArtifact(
    sessionID: String,
    artifact: ArtifactWriteRequest,
    createdAt: Date
  ) throws -> ArtifactRecord {
    try ensurePrepared()
    let validatedSessionID = try ValidatedSessionID(sessionID)
    guard try sessionRevision(sessionID: validatedSessionID.rawValue) != nil else {
      throw AgentError.sessionNotFound(validatedSessionID.rawValue)
    }
    let contentSHA256 = try StoreArtifactIntegrity.digestForWrite(artifact.data)

    let artifactID = try ValidatedArtifactID(artifactIDGenerator()).rawValue
    var knownArtifactIDs = try knownArtifactIDsForMutation(
      sessionID: validatedSessionID.rawValue
    )
    guard knownArtifactIDs.insert(artifactID).inserted else {
      throw AgentError.persistenceFailure(
        "Artifact identifier already exists: \(artifactID)."
      )
    }
    issuedArtifactIDsBySession[validatedSessionID.rawValue] = knownArtifactIDs

    var stagedURL: URL?
    do {
      let artifactsDirectory = layout.artifactsDirectoryURL(
        sessionID: validatedSessionID.rawValue
      )
      try fileManager.createDirectory(
        at: artifactsDirectory,
        withIntermediateDirectories: true
      )
      let plan = ArtifactStoragePlan(
        sessionID: validatedSessionID,
        preferredFilename: artifact.preferredFilename,
        rootURL: layout.rootURL,
        artifactID: artifactID
      )
      let absoluteURL = try sandboxGuard.validateFileURL(plan.absoluteURL)
      stagedURL = absoluteURL
      guard fileManager.fileExists(atPath: absoluteURL.path) == false else {
        throw AgentError.persistenceFailure(
          "Artifact file already exists: \(plan.filename)."
        )
      }
      try artifact.data.write(to: absoluteURL, options: .atomic)
      try dataPolicy.apply(to: absoluteURL, fileManager: fileManager)

      return ArtifactRecord(
        id: plan.artifactID,
        sessionID: validatedSessionID.rawValue,
        filename: plan.filename,
        relativePath: plan.relativePath,
        mimeType: artifact.mimeType,
        byteCount: artifact.data.count,
        contentSHA256: contentSHA256,
        createdAt: createdAt,
        metadata: artifact.metadata
      )
    } catch {
      let primaryError = error
      var known = issuedArtifactIDsBySession[validatedSessionID.rawValue] ?? []
      known.remove(artifactID)
      issuedArtifactIDsBySession[validatedSessionID.rawValue] = known
      if let stagedURL, fileManager.fileExists(atPath: stagedURL.path) {
        do {
          try fileManager.removeItem(at: stagedURL)
        } catch {
          throw AgentError.persistenceFailure(
            "Artifact staging failed [\(primaryError.localizedDescription)] "
              + "and cleanup also failed [\(error.localizedDescription)]."
          )
        }
      }
      throw primaryError
    }
  }

  func discardUnreferencedArtifact(_ artifact: ArtifactRecord) throws {
    try ensurePrepared()
    let sessionID = try ValidatedSessionID(artifact.sessionID).rawValue
    let artifactID = try ValidatedArtifactID(artifact.id).rawValue
    guard artifact.filename.hasPrefix("\(artifactID)-"),
      artifact.relativePath == "sessions/\(sessionID)/artifacts/\(artifact.filename)"
    else {
      throw AgentError.persistenceFailure(
        "Artifact cleanup record does not match its storage identity."
      )
    }
    let artifactURL = try validateArtifactURL(for: artifact)

    try requiredDatabase.inTransaction {
      let referenced = try requiredDatabase.query(
        """
        SELECT 1
        FROM session_artifacts
        WHERE session_id = ? AND artifact_id = ?
        LIMIT 1
        """,
        parameters: [.text(sessionID), .text(artifactID)]
      )
      guard referenced.isEmpty else { return }
      if fileManager.fileExists(atPath: artifactURL.path) {
        try fileManager.removeItem(at: artifactURL)
      }
      var known = issuedArtifactIDsBySession[sessionID] ?? []
      known.remove(artifactID)
      issuedArtifactIDsBySession[sessionID] = known
    }
  }

  func loadArtifact(sessionID: String, artifactID: String) throws -> Data {
    try ensurePrepared()
    let validatedSessionID = try ValidatedSessionID(sessionID)
    let validatedArtifactID = try ValidatedArtifactID(artifactID)
    let rows = try requiredDatabase.query(
      """
      SELECT payload
      FROM session_artifacts
      WHERE session_id = ? AND artifact_id = ?
      """,
      parameters: [
        .text(validatedSessionID.rawValue),
        .text(validatedArtifactID.rawValue),
      ]
    )
    guard let row = rows.first else {
      throw AgentError.notFound("Artifact not found: \(artifactID)")
    }
    let record = try StoreCodecs.decode(ArtifactRecord.self, from: row.blob(0))
    let absoluteURL = try validateArtifactURL(for: record)
    return try StoreArtifactIntegrity.loadPayload(at: absoluteURL, record: record)
  }

  func sandboxRootURL() throws -> URL {
    try ensurePrepared()
    return layout.rootURL
  }

  func sessionDirectoryURL(sessionID: String) throws -> URL {
    try ensurePrepared()
    let validated = try ValidatedSessionID(sessionID)
    guard try sessionRevision(sessionID: validated.rawValue) != nil else {
      throw AgentError.sessionNotFound(validated.rawValue)
    }
    let url = layout.sessionRootURL(sessionID: validated.rawValue)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func knownArtifactIDsForMutation(sessionID: String) throws -> Set<String> {
    if let known = issuedArtifactIDsBySession[sessionID] {
      return known
    }
    let rows = try requiredDatabase.query(
      "SELECT artifact_id FROM session_artifacts WHERE session_id = ?",
      parameters: [.text(sessionID)]
    )
    let known = Set(try rows.map { try $0.text(0) })
    issuedArtifactIDsBySession[sessionID] = known
    return known
  }

  func validateArtifactURL(for record: ArtifactRecord) throws -> URL {
    let url = layout.rootURL.appendingPathComponent(
      record.relativePath,
      isDirectory: false
    )
    return try sandboxGuard.validateFileURL(url)
  }
}
