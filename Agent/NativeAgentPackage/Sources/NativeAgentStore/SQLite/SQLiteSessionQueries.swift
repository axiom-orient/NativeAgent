import Foundation
import NativeAgentDomain

// Read projections share SQLiteSessionStore actor isolation and its only connection.
extension SQLiteSessionStore {
  func loadSessionSummary(sessionID: String) throws -> SessionSummary? {
    try ensurePrepared()
    let validated = try ValidatedSessionID(sessionID)
    let rows = try requiredDatabase.query(
      """
      SELECT
          session_id,
          revision,
          title,
          status,
          created_at,
          updated_at,
          provider_id,
          model_id,
          message_count,
          artifact_count
      FROM sessions
      WHERE session_id = ?
      """,
      parameters: [.text(validated.rawValue)]
    )
    guard let row = rows.first else { return nil }
    return try sessionSummary(from: row)
  }

  func loadSessionStateView(sessionID: String) throws -> SessionStateView? {
    try ensurePrepared()
    let validated = try ValidatedSessionID(sessionID)
    let rows = try requiredDatabase.query(
      """
      SELECT
          session_id, revision, title, status, created_at, updated_at,
          provider_id, model_id, message_count, artifact_count,
          metadata, context_checkpoint, wait_state, failure, last_signal
      FROM sessions
      WHERE session_id = ?
      """,
      parameters: [.text(validated.rawValue)]
    )
    guard let row = rows.first else { return nil }
    let summary = try sessionSummary(from: row)
    return SessionStateView(
      summary: summary,
      metadata: try StoreCodecs.decode([String: JSONValue].self, from: row.blob(10)),
      contextCheckpoint: try decodeStateValue(
        SessionContextCheckpoint.self,
        data: row.optionalBlob(11)
      ),
      waitState: try decodeStateValue(
        SessionWaitState.self,
        data: row.optionalBlob(12)
      ),
      failure: try decodeStateValue(
        SessionFailure.self,
        data: row.optionalBlob(13)
      ),
      lastSignal: try decodeStateValue(
        SessionSignal.self,
        data: row.optionalBlob(14)
      )
    )
  }

  func listSessionSummaries(limit: Int, offset: Int) throws -> [SessionSummary] {
    try ensurePrepared()
    try SessionReadLimits.validatePage(limit: limit, offset: offset)
    let rows = try requiredDatabase.query(
      """
      SELECT
          session_id,
          revision,
          title,
          status,
          created_at,
          updated_at,
          provider_id,
          model_id,
          message_count,
          artifact_count
      FROM sessions
      ORDER BY updated_at DESC, session_id ASC
      LIMIT ? OFFSET ?
      """,
      parameters: [.integer(Int64(limit)), .integer(Int64(offset))]
    )
    return try rows.map(sessionSummary(from:))
  }

  func querySessionList(_ query: SessionListQuery) async throws -> [SessionListItem] {
    let validated = try ValidatedSessionQuery(
      sessionIDs: query.sessionIDs,
      keywords: query.keywords,
      startDate: query.startDate,
      endDate: query.endDate,
      limit: query.limit,
      offset: query.offset
    )
    try ensurePrepared()

    var predicates: [String] = []
    var parameters: [StoreSQLValue] = []
    appendSessionIDPredicate(
      validated.sessionIDs,
      column: "s.session_id",
      to: &predicates,
      parameters: &parameters
    )
    if let startDate = validated.startDate {
      predicates.append("s.updated_at >= ?")
      parameters.append(.real(startDate.timeIntervalSince1970))
    }
    if let endDate = validated.endDate {
      predicates.append("s.updated_at <= ?")
      parameters.append(.real(endDate.timeIntervalSince1970))
    }
    for keyword in validated.keywords {
      let pattern = StoreSQLValue.text(escapeLikePattern(keyword))
      predicates.append(
        """
        (
            LOWER(COALESCE(s.title, '')) LIKE ? ESCAPE '\\'
            OR EXISTS (
                SELECT 1
                FROM session_messages keyword_message
                WHERE keyword_message.session_id = s.session_id
                  AND LOWER(COALESCE(
                      CAST(json_extract(
                          CAST(keyword_message.payload AS TEXT), '$.content'
                      ) AS TEXT),
                      ''
                  )) LIKE ? ESCAPE '\\'
            )
        )
        """
      )
      parameters.append(pattern)
      parameters.append(pattern)
    }
    if validated.sessionIDs?.isEmpty == true {
      predicates.append("0 = 1")
    }

    let whereClause =
      predicates.isEmpty
      ? ""
      : "WHERE " + predicates.joined(separator: " AND ")
    parameters.append(.integer(Int64(validated.limit)))
    parameters.append(.integer(Int64(validated.offset)))

    do {
      let rows = try requiredDatabase.query(
        """
        SELECT
            s.session_id,
            s.revision,
            s.title,
            s.status,
            s.created_at,
            s.updated_at,
            s.provider_id,
            s.model_id,
            s.message_count,
            s.artifact_count,
            CASE
                WHEN json_type(
                    CAST(s.metadata AS TEXT), '$."uihost.source"'
                ) = 'text'
                THEN NULLIF(
                    json_extract(CAST(s.metadata AS TEXT), '$."uihost.source"'),
                    ''
                )
                ELSE NULL
            END AS source,
            latest_message.payload
        FROM sessions s
        LEFT JOIN session_messages latest_message
            ON latest_message.session_id = s.session_id
           AND latest_message.ordinal = (
               SELECT candidate.ordinal
               FROM session_messages candidate
               WHERE candidate.session_id = s.session_id
                 AND COALESCE(
                     CAST(json_extract(
                         CAST(candidate.payload AS TEXT), '$.content'
                     ) AS TEXT),
                     ''
                 ) <> ''
               ORDER BY candidate.ordinal DESC
               LIMIT 1
           )
        \(whereClause)
        ORDER BY s.updated_at DESC, s.session_id ASC
        LIMIT ? OFFSET ?
        """,
        parameters: parameters
      ).map { row in
        let summary = try sessionSummary(from: row)
        let preview: String?
        if let payload = try row.optionalBlob(11) {
          preview = try StoreCodecs.decode(AgentMessage.self, from: payload).content
        } else {
          preview = nil
        }
        return SessionListItem(
          summary: summary,
          preview: preview?.isEmpty == false ? preview : nil,
          source: try row.optionalText(10)
        )
      }
      return rows
    } catch {
      throw queryFailure(operation: "querySessionList", error: error)
    }
  }

  func searchSessionMessages(
    _ query: SessionMessageSearchQuery
  ) async throws -> SessionMessageSearchPage {
    let validated = try ValidatedSessionQuery(
      sessionIDs: query.sessionIDs,
      keywords: query.keywords,
      startDate: query.startDate,
      endDate: query.endDate,
      limit: query.limit,
      offset: query.offset
    )
    try ensurePrepared()

    var predicates: [String] = []
    var parameters: [StoreSQLValue] = []
    appendSessionIDPredicate(
      validated.sessionIDs,
      column: "m.session_id",
      to: &predicates,
      parameters: &parameters
    )
    for keyword in validated.keywords {
      predicates.append(
        """
        LOWER(COALESCE(
            CAST(json_extract(CAST(m.payload AS TEXT), '$.content') AS TEXT),
            ''
        )) LIKE ? ESCAPE '\\'
        """
      )
      parameters.append(.text(escapeLikePattern(keyword)))
    }
    if let startDate = validated.startDate {
      predicates.append(
        "CAST(json_extract(CAST(m.payload AS TEXT), '$.createdAt') AS REAL) / 1000.0 >= ?"
      )
      parameters.append(.real(startDate.timeIntervalSince1970))
    }
    if let endDate = validated.endDate {
      predicates.append(
        "CAST(json_extract(CAST(m.payload AS TEXT), '$.createdAt') AS REAL) / 1000.0 <= ?"
      )
      parameters.append(.real(endDate.timeIntervalSince1970))
    }
    if validated.sessionIDs?.isEmpty == true {
      predicates.append("0 = 1")
    }
    let whereClause =
      predicates.isEmpty
      ? "1 = 1"
      : predicates.joined(separator: " AND ")
    parameters.append(.integer(Int64(validated.limit)))
    parameters.append(.integer(Int64(validated.offset)))

    do {
      let rows = try requiredDatabase.query(
        """
        WITH filtered AS (
            SELECT
                m.session_id,
                s.title,
                m.payload,
                m.ordinal,
                CAST(json_extract(CAST(m.payload AS TEXT), '$.createdAt') AS REAL)
                    AS message_created_at
            FROM session_messages m
            LEFT JOIN sessions s ON s.session_id = m.session_id
            WHERE \(whereClause)
        ),
        paged AS (
            SELECT session_id, title, payload, ordinal, message_created_at
            FROM filtered
            ORDER BY message_created_at DESC, session_id ASC, ordinal DESC
            LIMIT ? OFFSET ?
        )
        SELECT
            (SELECT COUNT(*) FROM filtered) AS total_count,
            paged.session_id,
            paged.title,
            paged.payload,
            paged.message_created_at,
            paged.ordinal
        FROM (SELECT 1 AS anchor) AS anchor
        LEFT JOIN paged ON 1 = 1
        ORDER BY paged.message_created_at DESC, paged.session_id ASC, paged.ordinal DESC
        """,
        parameters: parameters
      )
      guard let firstRow = rows.first else {
        throw AgentError.persistenceFailure(
          "SQLite message search returned no total-count row."
        )
      }
      let totalCount = try integerCount(firstRow.integer(0), field: "message search")
      let matches = try rows.compactMap { row -> SessionMessageSearchMatch? in
        guard let sessionID = try row.optionalText(1) else { return nil }
        guard let payload = try row.optionalBlob(3) else {
          throw AgentError.persistenceFailure(
            "SQLite message search row is missing its payload."
          )
        }
        return SessionMessageSearchMatch(
          sessionID: sessionID,
          sessionTitle: try row.optionalText(2),
          message: try StoreCodecs.decode(AgentMessage.self, from: payload)
        )
      }
      return SessionMessageSearchPage(
        totalCount: totalCount,
        offset: validated.offset,
        matches: matches
      )
    } catch {
      throw queryFailure(operation: "searchSessionMessages", error: error)
    }
  }

  private func sessionSummary(from row: StoreSQLRow) throws -> SessionSummary {
    let statusRaw = try row.text(3)
    guard let status = SessionStatus(rawValue: statusRaw) else {
      throw AgentError.persistenceFailure(
        "SQLite session summary has unknown status \(statusRaw)."
      )
    }
    return SessionSummary(
      sessionID: try row.text(0),
      revision: try row.integer(1),
      title: try row.optionalText(2),
      status: status,
      createdAt: Date(timeIntervalSince1970: try row.real(4)),
      updatedAt: Date(timeIntervalSince1970: try row.real(5)),
      providerID: try row.optionalText(6),
      modelID: try row.optionalText(7),
      messageCount: try integerCount(row.integer(8), field: "message"),
      artifactCount: try integerCount(row.integer(9), field: "artifact")
    )
  }

  private func decodeStateValue<T: Decodable>(
    _ type: T.Type,
    data: Data?
  ) throws -> T? {
    guard let data else { return nil }
    return try StoreCodecs.decode(type, from: data)
  }

  func loadSessionMessages(
    sessionID: String,
    offset: Int,
    limit: Int
  ) throws -> SessionMessagePage {
    try ensurePrepared()
    try SessionReadLimits.validatePage(limit: limit, offset: offset)
    let validated = try ValidatedSessionID(sessionID)
    let countRows = try requiredDatabase.query(
      "SELECT message_count FROM sessions WHERE session_id = ?",
      parameters: [.text(validated.rawValue)]
    )
    guard let countRow = countRows.first else {
      throw AgentError.sessionNotFound(validated.rawValue)
    }
    let totalCount = try integerCount(
      countRow.integer(0),
      field: "message"
    )
    let rows = try requiredDatabase.query(
      """
      SELECT payload
      FROM session_messages
      WHERE session_id = ?
      ORDER BY ordinal ASC
      LIMIT ? OFFSET ?
      """,
      parameters: [
        .text(validated.rawValue),
        .integer(Int64(limit)),
        .integer(Int64(offset)),
      ]
    )
    return SessionMessagePage(
      sessionID: validated.rawValue,
      offset: offset,
      totalCount: totalCount,
      messages: try rows.map {
        try StoreCodecs.decode(AgentMessage.self, from: $0.blob(0))
      }
    )
  }

  private func appendSessionIDPredicate(
    _ sessionIDs: [String]?,
    column: String,
    to predicates: inout [String],
    parameters: inout [StoreSQLValue]
  ) {
    guard let sessionIDs, sessionIDs.isEmpty == false else { return }
    let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
    predicates.append("\(column) IN (\(placeholders))")
    parameters.append(contentsOf: sessionIDs.map(StoreSQLValue.text))
  }

  private func queryFailure(operation: String, error: any Error) -> AgentError {
    AgentError.persistenceFailure(
      "SQLite \(operation) failed: \(error.localizedDescription)"
    )
  }

}

private struct ValidatedSessionQuery {
  let sessionIDs: [String]?
  let keywords: [String]
  let startDate: Date?
  let endDate: Date?
  let limit: Int
  let offset: Int

  init(
    sessionIDs: [String]?,
    keywords: [String],
    startDate: Date?,
    endDate: Date?,
    limit: Int,
    offset: Int = 0
  ) throws {
    let validated = try SessionReadLimits.validated(
      SessionListQuery(
        sessionIDs: sessionIDs,
        keywords: keywords,
        startDate: startDate,
        endDate: endDate,
        limit: limit,
        offset: offset
      )
    )
    self.sessionIDs = try validated.sessionIDs.map { ids in
      try ids.map { try ValidatedSessionID($0).rawValue }
    }
    self.keywords = validated.keywords
    self.startDate = startDate
    self.endDate = endDate
    self.limit = limit
    self.offset = offset
  }
}

private func escapeLikePattern(_ keyword: String) -> String {
  "%"
    + keyword
    .lowercased()
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_") + "%"
}
