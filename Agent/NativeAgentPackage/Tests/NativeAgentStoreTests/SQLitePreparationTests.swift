import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentStore

private func persistedFiles(_ root: URL) throws -> [String: Data] {
  let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
  var result: [String: Data] = [:]
  for case let url as URL in files {
    if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
    }
  }
  return result
}

private func makeUnsupportedStore(_ root: URL, kind: String) throws {
  let layout = StoreLayout(rootURL: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  if kind != "missing-manifest" {
    try StoreManifestIO(layout: layout, fileManager: .default).writeManifest(StoreManifest())
  }
  if kind == "missing-database" { return }
  let database = try StoreSQLiteConnection(url: layout.databaseURL)
  if kind == "foreign" {
    try database.executeScript("CREATE TABLE foreign_data(value TEXT); INSERT INTO foreign_data VALUES('preserve');")
    return
  }
  var schema = sqliteSessionSchema
  if kind == "missing-effects-primary-key" {
    schema = schema.replacingOccurrences(of: "    PRIMARY KEY (session_id, scope, effect_key),\n", with: "")
  }
  if kind == "incompatible-sequence-type" {
    schema = schema.replacingOccurrences(of: "sequence INTEGER PRIMARY KEY AUTOINCREMENT", with: "sequence INT PRIMARY KEY NOT NULL")
  }
  if kind == "descending-sequence-key" {
    schema = schema.replacingOccurrences(of: "sequence INTEGER PRIMARY KEY AUTOINCREMENT", with: "sequence INTEGER PRIMARY KEY DESC")
  }
  if kind == "missing-sequence-autoincrement" {
    schema = schema.replacingOccurrences(of: "sequence INTEGER PRIMARY KEY AUTOINCREMENT", with: "sequence INTEGER PRIMARY KEY")
  }
  if kind == "missing-required-notnull" {
    schema = schema.replacingOccurrences(of: "status TEXT NOT NULL", with: "status TEXT")
  }
  try database.executeScript(schema)
  if !kind.hasPrefix("missing-version") {
    try database.execute("INSERT INTO store_metadata(key,value) VALUES('schema_version',?)",
                         parameters: [.text(kind.hasPrefix("future-version") ? "99" : "1")])
  }
  if kind == "missing-table" {
    try database.execute("DROP TABLE session_effects")
  }
  if kind.hasSuffix("-wal") { try database.executeScript("PRAGMA journal_mode=WAL;") }
}

private func makeCommittedWAL(for databaseURL: URL) throws -> Data {
  let writer = try StoreSQLiteConnection(url: databaseURL)
  try writer.inTransaction {
    try writer.execute(
      "UPDATE store_metadata SET value = '99' WHERE key = 'schema_version'"
    )
    try writer.execute(
      "INSERT INTO store_metadata(key, value) VALUES('wal_probe', 'committed')"
    )
  }
  return try Data(contentsOf: URL(fileURLWithPath: databaseURL.path + "-wal"))
}

@Test(arguments: ["missing-version", "future-version", "foreign", "missing-manifest", "missing-database", "missing-table", "future-version-wal", "missing-version-wal", "missing-effects-primary-key", "incompatible-sequence-type", "missing-required-notnull", "descending-sequence-key", "missing-sequence-autoincrement"])
func sqlitePreparationRejectsUnsupportedStorageWithoutChangingBytes(kind: String) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-preflight-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  try makeUnsupportedStore(root, kind: kind)
  let before = try persistedFiles(root)
  let store = ApplicationSupportSessionStore(rootURL: root)
  do {
    try await store.prepare()
    Issue.record("Expected unsupported store preparation to fail")
  } catch {
    #expect(error is AgentError)
  }
  let after = try persistedFiles(root)
  let added = Set(after.keys).subtracting(before.keys).sorted()
  let removed = Set(before.keys).subtracting(after.keys).sorted()
  let changed = before.keys.filter { before[$0] != after[$0] }.sorted()
  #expect(
    added.isEmpty && removed.isEmpty && changed.isEmpty,
    "Unsupported \(kind) changed files: added \(added), removed \(removed), changed \(changed)"
  )
}

@Test
func sqliteWALPreflightReadsCrashLeftCommitAndPreservesFiles() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-wal-preflight-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  try makeUnsupportedStore(root, kind: "valid-wal")

  let layout = StoreLayout(rootURL: root)
  let originalDatabase = try Data(contentsOf: layout.databaseURL)
  let walURL = URL(fileURLWithPath: layout.databaseURL.path + "-wal")
  let sharedMemoryURL = URL(fileURLWithPath: layout.databaseURL.path + "-shm")
  let committedWAL = try makeCommittedWAL(for: layout.databaseURL)
  #expect(committedWAL.count > 32)

  if FileManager.default.fileExists(atPath: sharedMemoryURL.path) {
    try FileManager.default.removeItem(at: sharedMemoryURL)
  }
  #expect(FileManager.default.fileExists(atPath: sharedMemoryURL.path) == false)
  try originalDatabase.write(to: layout.databaseURL)
  try committedWAL.write(to: walURL)
  let before = try persistedFiles(root)

  let store = ApplicationSupportSessionStore(rootURL: root)
  await #expect(throws: AgentError.self) { try await store.prepare() }
  #expect(try persistedFiles(root) == before)
}

@Test
func sqliteWALPreflightAllowsConcurrentWriter() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-wal-writer-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  try makeUnsupportedStore(root, kind: "valid-wal")

  let layout = StoreLayout(rootURL: root)
  let writer = try StoreSQLiteConnection(url: layout.databaseURL)
  try writer.execute("PRAGMA busy_timeout = 0")
  try writer.inTransaction {
    try writer.execute(
      "INSERT INTO store_metadata(key, value) VALUES('writer_probe', 'before')"
    )
  }
  let before = try persistedFiles(root)

  let inspection = try StoreSQLiteConnection.schemaPreflightConnection(at: layout.databaseURL)
  let rows = try inspection.query(
    "SELECT value FROM store_metadata WHERE key = 'writer_probe'"
  )
  #expect(rows.count == 1)
  #expect(try rows[0].text(0) == "before")
  let afterInspection = try persistedFiles(root)
  let addedFiles = Set(afterInspection.keys).subtracting(before.keys).sorted()
  let removedFiles = Set(before.keys).subtracting(afterInspection.keys).sorted()
  let changedDurableFiles = before.keys
    .filter { !$0.hasSuffix("-shm") && before[$0] != afterInspection[$0] }
    .sorted()
  #expect(
    addedFiles.isEmpty && removedFiles.isEmpty && changedDurableFiles.isEmpty,
    "preflight added \(addedFiles), removed \(removedFiles), or changed \(changedDurableFiles)"
  )

  try writer.inTransaction {
    try writer.execute(
      "UPDATE store_metadata SET value = 'during' WHERE key = 'writer_probe'"
    )
  }
  let committedWhileInspecting = try inspection.query(
    "SELECT value FROM store_metadata WHERE key = 'writer_probe'"
  )
  #expect(try committedWhileInspecting[0].text(0) == "during")
  try inspection.finishSchemaPreflight()
  let updated = try writer.query(
    "SELECT value FROM store_metadata WHERE key = 'writer_probe'"
  )
  #expect(try updated[0].text(0) == "during")
}

@Test
func sqlitePreparationSerializesConcurrentBootstrapAndReopensCurrentData() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-bootstrap-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let first = ApplicationSupportSessionStore(rootURL: root)
  let second = ApplicationSupportSessionStore(rootURL: root)
  async let a: Void = first.prepare()
  async let b: Void = second.prepare()
  _ = try await (a, b)
  try await first.createSession(SessionSnapshot(sessionID: "retained"), events: [], effects: [])
  #expect(try await second.loadSnapshot(sessionID: "retained")?.sessionID == "retained")
}
