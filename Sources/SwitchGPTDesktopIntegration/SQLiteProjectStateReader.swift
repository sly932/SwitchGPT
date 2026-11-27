import Darwin
import Foundation
import SQLite3

enum SQLiteProjectStateReader {
  private static let maximumSelectedBytes = 64 * 1024 * 1024

  static func read(at url: URL, keys: [String]) throws -> [String: Data]? {
    guard let path = try checkedPath(at: url) else { return nil }

    var handle: OpaquePointer?
    let result = path.withCString {
      sqlite3_open_v2($0, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
    }
    defer { if let handle { sqlite3_close(handle) } }
    try check(result, expecting: SQLITE_OK)
    guard let handle else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    try check(sqlite3_busy_timeout(handle, 250), expecting: SQLITE_OK)
    sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(maximumSelectedBytes))
    try execute("PRAGMA trusted_schema = OFF", in: handle)
    try execute("BEGIN DEFERRED", in: handle)
    defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }

    let version = try integer("PRAGMA main.user_version", in: handle)
    if version == 0, try integer("SELECT count(*) FROM main.sqlite_schema", in: handle) == 0 {
      // ChatGPT initializes the table and sets user_version in the same transaction.
      return nil
    }
    guard version == 1, try integer(settingsSchemaCheck, in: handle) == 1 else {
      throw LocalProjectStateSynchronizationError.unsupportedSchema
    }
    guard !keys.isEmpty else { return [:] }

    let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
    let sql = """
      SELECT key, value FROM main.settings
      WHERE scope COLLATE BINARY = 'global' AND key COLLATE BINARY IN (\(placeholders))
      """
    return try withStatement(sql, in: handle) { statement in
      for (index, key) in keys.enumerated() {
        let result = key.withCString {
          sqlite3_bind_text(
            statement, Int32(index + 1), $0, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
          )
        }
        try check(result, expecting: SQLITE_OK)
      }

      var selected: [String: Data] = [:]
      var remainingBytes = maximumSelectedBytes
      while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return selected }
        try check(step, expecting: SQLITE_ROW)
        guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
          sqlite3_column_type(statement, 1) == SQLITE_TEXT,
          let keyBytes = sqlite3_column_text(statement, 0),
          let key = String(
            bytes: UnsafeBufferPointer(start: keyBytes, count: Int(sqlite3_column_bytes(statement, 0))),
            encoding: .utf8
          ), selected[key] == nil,
          let valueBytes = sqlite3_column_text(statement, 1)
        else { throw LocalProjectStateSynchronizationError.invalidState }
        let count = Int(sqlite3_column_bytes(statement, 1))
        guard count > 0, count <= remainingBytes else {
          throw LocalProjectStateSynchronizationError.invalidState
        }
        selected[key] = Data(bytes: valueBytes, count: count)
        remainingBytes -= count
      }
    }
  }

  private static let settingsSchemaCheck = """
    SELECT EXISTS(SELECT 1 FROM main.sqlite_schema WHERE name = 'settings' AND type = 'table')
      AND (SELECT count(*) FROM pragma_table_xinfo('settings', 'main')) = 3
      AND (SELECT count(*) FROM pragma_table_xinfo('settings', 'main')
        WHERE upper(type) = 'TEXT' AND "notnull" = 1 AND hidden = 0
          AND ((name = 'scope' AND pk = 1) OR (name = 'key' AND pk = 2)
            OR (name = 'value' AND pk = 0))) = 3
    """

  private static func checkedPath(at url: URL) throws -> String? {
    // SQLite's NOFOLLOW also rejects directory aliases such as macOS /var.
    // Resolve the parent only so both lstat and SQLite still reject a symlink leaf.
    guard let parent = url.deletingLastPathComponent().path.withCString({ realpath($0, nil) }) else {
      if errno == ENOENT { return nil }
      throw LocalProjectStateSynchronizationError.unsafeStorage
    }
    defer { free(parent) }
    let path = URL(fileURLWithPath: String(cString: parent), isDirectory: true)
      .appendingPathComponent(url.lastPathComponent).path
    var status = stat()
    if path.withCString({ lstat($0, &status) }) != 0 {
      if errno == ENOENT { return nil }
      throw LocalProjectStateSynchronizationError.unsafeStorage
    }
    guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
      status.st_nlink == 1, status.st_mode & 0o022 == 0
    else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    return path
  }

  private static func execute(_ sql: String, in handle: OpaquePointer) throws {
    try check(sqlite3_exec(handle, sql, nil, nil, nil), expecting: SQLITE_OK)
  }

  private static func integer(_ sql: String, in handle: OpaquePointer) throws -> Int32 {
    try withStatement(sql, in: handle) { statement in
      try check(sqlite3_step(statement), expecting: SQLITE_ROW)
      guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
        throw LocalProjectStateSynchronizationError.invalidState
      }
      let value = sqlite3_column_int(statement, 0)
      try check(sqlite3_step(statement), expecting: SQLITE_DONE)
      return value
    }
  }

  private static func withStatement<T>(
    _ sql: String, in handle: OpaquePointer, _ operation: (OpaquePointer) throws -> T
  ) throws -> T {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    defer { if let statement { sqlite3_finalize(statement) } }
    try check(result, expecting: SQLITE_OK)
    guard let statement else { throw LocalProjectStateSynchronizationError.invalidState }
    return try operation(statement)
  }

  private static func check(_ result: Int32, expecting expected: Int32) throws {
    guard result != expected else { return }
    switch result & 0xff {
    case SQLITE_BUSY, SQLITE_LOCKED:
      throw LocalProjectStateSynchronizationError.transactionConflict
    case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY:
      throw LocalProjectStateSynchronizationError.unsafeStorage
    default:
      throw LocalProjectStateSynchronizationError.invalidState
    }
  }
}
