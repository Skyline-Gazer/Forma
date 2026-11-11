import Foundation
import SQLite3
import Testing

/// A temporary directory, its SQLite file and raw-SQL helpers, shared by the
/// suites that need a real workspace on disk.
struct SourceFixture {

    let base: URL
    let root: URL
    let database: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("source", isDirectory: true)
        database = base.appendingPathComponent("workspace.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    func write(_ text: String, at path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func execute(_ sql: String) throws {
        try withDatabase { connection in
            try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    func scalar(_ sql: String) throws -> String? {
        try withDatabase { connection in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(connection) }
        try #require(opened == SQLITE_OK)
        return try body(#require(connection))
    }
}
