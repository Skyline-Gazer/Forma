import CryptoKit
import Foundation
import GRDB

struct StoredSourceRoot: Sendable {
    let id: UUID
    let bookmark: Data
    let securityScoped: Bool
    let identity: String
    let lastPath: String
    let caseSensitive: Bool?

    init(_ row: Row) throws {
        id = try sourceUUID(row["id"])
        bookmark = row["bookmark"]
        securityScoped = row["security_scoped"]
        identity = row["resource_identity"]
        lastPath = row["last_path"]
        caseSensitive = row["case_sensitive"]
    }

    func withAccess<T>(_ body: (SourceRootAccess) throws -> T) throws -> T {
        var stale = false
        let options: URL.BookmarkResolutionOptions = securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        let url = try URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
        guard !stale else { throw FormaError.unauthorized }
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let root = try SourceRootAccess(url)
        guard root.rootIdentity == identity, root.caseSensitive == caseSensitive else { throw FormaError.unauthorized }
        return try body(root)
    }
}

struct StoredSourceEntry: Sendable {
    let entry: SourceEntry
    let stableIdentity: String?
    let objectKey: String?
    let fileType: Int64?
    let changeNanoseconds: Int64?

    init(_ row: Row) throws {
        guard let state = SourceEntryState(rawValue: row["state"]) else { throw FormaError.storage }
        guard let provider = SourceProvider(rawValue: row["provider"]) else { throw FormaError.storage }
        stableIdentity = row["resource_identity_value"]
        objectKey = row["object_key"]
        changeNanoseconds = row["change_ns"]
        fileType = row["file_type"]
        entry = .init(id: try sourceUUID(row["id"]), rootID: try sourceUUID(row["root_id"]),
                      relativePath: row["relative_path"], normalizedRelativePath: row["normalized_path"],
                      state: state, hydrationPending: row["hydration_pending"], sourceVersion: row["source_version"],
                      snapshotRevision: row["revision"], provider: provider, snapshotFingerprint: row["fingerprint"],
                      sizeBytes: row["size_bytes"], modificationTimeNanoseconds: row["mtime_ns"], sha256: row["sha256"])
    }

    func matches(_ metadata: SourceFileMetadata, stableIdentity currentIdentity: String?) -> Bool {
        // Hydration may add a newly available identifier or replace a provider's local inode.
        let canCompareLocalObject = !entry.hydrationPending && !metadata.isHydrationPending
        return entry.sizeBytes == metadata.sizeBytes && entry.modificationTimeNanoseconds == metadata.modifiedNanoseconds
            && fileType == metadata.fileType
            && (!canCompareLocalObject || objectKey == metadata.objectKey)
            && (stableIdentity == nil || currentIdentity == nil || stableIdentity == currentIdentity)
    }
}

func sourceUUID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw FormaError.storage }
    return id
}

extension UUID {
    var sourceKey: String { uuidString.lowercased() }
}

struct SourceStore {
    let database: DatabaseQueue

    init(url: URL) throws {
        guard url.isFileURL else { throw FormaError.storage }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        database = try DatabaseQueue(path: url.path)
        // Registered paths, snapshots and hashes stay owner-readable; SQLite also creates
        // sidecar files, so each one is restricted immediately after opening.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path + suffix)
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("source-workspace-v1") { db in
            try db.execute(sql: """
                CREATE TABLE source_roots (
                    id TEXT PRIMARY KEY NOT NULL,
                    bookmark BLOB NOT NULL,
                    security_scoped INTEGER NOT NULL,
                    resource_identity TEXT NOT NULL UNIQUE,
                    last_path TEXT NOT NULL,
                    case_sensitive INTEGER
                );
                CREATE TABLE source_scopes (
                    id TEXT PRIMARY KEY NOT NULL,
                    root_id TEXT NOT NULL REFERENCES source_roots(id),
                    relative_path TEXT NOT NULL,
                    normalized_path TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    UNIQUE(root_id, normalized_path)
                );
                CREATE TABLE scans (
                    id TEXT PRIMARY KEY NOT NULL,
                    scope_id TEXT NOT NULL REFERENCES source_scopes(id),
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    statistics BLOB,
                    state TEXT NOT NULL CHECK(state IN ('scanning', 'complete', 'incomplete', 'cancelled', 'interrupted'))
                );
                CREATE INDEX scans_scope ON scans(scope_id);
                CREATE TABLE source_scan_issues (
                    scan_id TEXT NOT NULL REFERENCES scans(id),
                    relative_path TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    PRIMARY KEY(scan_id, relative_path, reason)
                );
                CREATE TABLE source_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    root_id TEXT NOT NULL REFERENCES source_roots(id),
                    relative_path TEXT NOT NULL,
                    normalized_path TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('present', 'missing', 'symlink', 'held')),
                    hydration_pending INTEGER NOT NULL,
                    provider TEXT NOT NULL,
                    object_key TEXT,
                    file_type INTEGER,
                    change_ns INTEGER,
                    current_revision INTEGER NOT NULL,
                    UNIQUE(root_id, normalized_path),
                    FOREIGN KEY(id, current_revision) REFERENCES source_snapshots(source_id, revision)
                        DEFERRABLE INITIALLY DEFERRED
                );
                CREATE TABLE source_snapshots (
                    source_id TEXT NOT NULL REFERENCES source_entries(id),
                    revision INTEGER NOT NULL,
                    source_version INTEGER NOT NULL,
                    format TEXT NOT NULL CHECK(format = 'snapshot.v1'),
                    scan_id TEXT REFERENCES scans(id),
                    size_bytes INTEGER,
                    mtime_ns INTEGER,
                    resource_identity_kind TEXT,
                    resource_identity_value TEXT,
                    provider_version TEXT,
                    sha256 TEXT,
                    hash_strength TEXT NOT NULL CHECK(hash_strength IN ('metadata', 'sha256')),
                    fingerprint TEXT NOT NULL,
                    PRIMARY KEY(source_id, revision)
                );
                CREATE TABLE path_history (
                    source_id TEXT NOT NULL REFERENCES source_entries(id),
                    scan_id TEXT REFERENCES scans(id),
                    previous_path TEXT,
                    relative_path TEXT NOT NULL,
                    recorded_at REAL NOT NULL
                );
                CREATE TABLE source_move_candidates (
                    previous_id TEXT NOT NULL REFERENCES source_entries(id),
                    candidate_id TEXT NOT NULL REFERENCES source_entries(id),
                    reason TEXT NOT NULL,
                    PRIMARY KEY(previous_id, candidate_id, reason),
                    CHECK(previous_id <> candidate_id)
                );
                """)
        }
        // Mapping state arrives after the source tables it references, so the
        // foreign keys in `mapping-v1` can resolve against a migrated schema.
        MappingMigrations.register(into: &migrator)
        try migrator.migrate(database)
        try database.write { db in
            try db.execute(sql: "UPDATE scans SET state = 'interrupted', finished_at = ? WHERE state = 'scanning'",
                           arguments: [Date().timeIntervalSince1970])
            // A run that never reached a terminal state cannot be resumed: the
            // engine must not attach a manifest to an unfinished run.
            try MappingStore.markInterruptedRuns(in: db)
        }
    }

    static func root(_ db: Database, id: UUID) throws -> StoredSourceRoot {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_roots WHERE id = ?", arguments: [id.sourceKey])
        else { throw FormaError.invalidSource }
        return try StoredSourceRoot(row)
    }

    static func scope(_ db: Database, id: UUID) throws -> SourceScope {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_scopes WHERE id = ?", arguments: [id.sourceKey])
        else { throw FormaError.invalidSource }
        return try scope(row)
    }

    static func scope(_ row: Row) throws -> SourceScope {
        .init(id: try sourceUUID(row["id"]), rootID: try sourceUUID(row["root_id"]),
              relativePath: row["relative_path"], displayName: row["display_name"])
    }

    static let entriesSQL = """
        SELECT e.*, s.* FROM source_entries e JOIN source_snapshots s
            ON s.source_id = e.id AND s.revision = e.current_revision
        """

    static func entries(_ db: Database, root: UUID) throws -> [StoredSourceEntry] {
        try Row.fetchAll(db, sql: entriesSQL + " WHERE e.root_id = ? ORDER BY e.normalized_path",
                         arguments: [root.sourceKey]).map(StoredSourceEntry.init)
    }

    static func entry(_ db: Database, id: UUID) throws -> StoredSourceEntry {
        guard let row = try Row.fetchOne(db, sql: entriesSQL + " WHERE e.id = ?", arguments: [id.sourceKey])
        else { throw FormaError.invalidSource }
        return try StoredSourceEntry(row)
    }

    static func listing(_ db: Database, scope: SourceScope) throws -> SourceListing {
        let last = try Row.fetchOne(db, sql: "SELECT * FROM scans WHERE scope_id = ? ORDER BY rowid DESC LIMIT 1",
                                    arguments: [scope.id.sourceKey])
        let state: SourceScanState
        let scanID: UUID?
        if let last {
            guard let status = SourceScanState(rawValue: last["state"]) else { throw FormaError.storage }
            state = status
            scanID = try sourceUUID(last["id"])
        } else {
            state = .notScanned
            scanID = nil
        }
        let root = try root(db, id: scope.rootID)
        let prefix = try root.caseSensitive.map { try SourcePath.normalize(scope.relativePath, caseSensitive: $0) } ?? ""
        let entries = try entries(db, root: root.id).compactMap { record in
            SourcePath.contains(record.entry.normalizedRelativePath, in: prefix) ? record.entry : nil
        }
        var issues: [SourceScanIssue] = []
        if let scanID {
            issues = try Row.fetchAll(db, sql: """
                SELECT relative_path, reason FROM source_scan_issues WHERE scan_id = ? ORDER BY relative_path, reason
                """, arguments: [scanID.sourceKey]).map { row in
                    guard let reason = SourceScanIssue.Reason(rawValue: row["reason"]) else { throw FormaError.storage }
                    return SourceScanIssue(relativePath: row["relative_path"], reason: reason)
                }
        }
        let statisticsData: Data? = last?["statistics"]
        let statistics = try statisticsData.map { try JSONDecoder().decode(SourceScanStatistics.self, from: $0) }
        return .init(scope: scope, scanID: scanID, state: state, entries: entries, issues: issues, statistics: statistics)
    }

    static func pathHistory(_ db: Database, id: UUID, scanID: UUID?, from: String?, to: String) throws {
        try db.execute(sql: """
            INSERT INTO path_history(source_id, scan_id, previous_path, relative_path, recorded_at) VALUES (?, ?, ?, ?, ?)
            """, arguments: [id.sourceKey, scanID?.sourceKey, from, to, Date().timeIntervalSince1970])
    }

    static func finishScan(_ db: Database, id: UUID, state: SourceScanState, issues: [SourceScanIssue] = [],
                           statistics: SourceScanStatistics? = nil) throws {
        let data = try statistics.map { try JSONEncoder().encode($0) }
        try db.execute(sql: "UPDATE scans SET state = ?, finished_at = ?, statistics = ? WHERE id = ? AND state = 'scanning'",
                       arguments: [state.rawValue, Date().timeIntervalSince1970, data, id.sourceKey])
        guard db.changesCount == 1 else { throw FormaError.sourceChanged }
        for issue in issues {
            try db.execute(sql: "INSERT OR IGNORE INTO source_scan_issues VALUES (?, ?, ?)",
                           arguments: [id.sourceKey, issue.relativePath, issue.reason.rawValue])
        }
    }

    static func appendSnapshot(_ db: Database, id: UUID, revision: Int64, version: Int64, scanID: UUID?,
                               size: Int64?, mtime: Int64?, identity: String?, sha256: String?) throws {
        let kind = identity == nil ? nil : "local-filesystem-resource"
        let fingerprint = SourceSnapshot.fingerprint(id: id, version: version, size: size, mtime: mtime,
                                                     kind: kind, identity: identity, providerVersion: nil, sha256: sha256)
        try db.execute(sql: """
            INSERT INTO source_snapshots(source_id, revision, source_version, format, scan_id, size_bytes, mtime_ns,
                resource_identity_kind, resource_identity_value, provider_version, sha256, hash_strength, fingerprint)
            VALUES (?, ?, ?, 'snapshot.v1', ?, ?, ?, ?, ?, NULL, ?, ?, ?)
            """, arguments: [id.sourceKey, revision, version, scanID?.sourceKey, size, mtime, kind, identity, sha256,
                              sha256 == nil ? "metadata" : "sha256", fingerprint])
    }
}

enum SourceSnapshot {
    static func fingerprint(id: UUID, version: Int64, size: Int64?, mtime: Int64?, kind: String?,
                            identity: String?, providerVersion: String?, sha256: String?) -> String {
        func jsonString(_ value: String?) -> String {
            guard let value else { return "null" }
            var result = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x22: result += "\\\""
                case 0x5C: result += "\\\\"
                case 0x00...0x1F: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
        let json = """
            {"source_id":\(jsonString(id.sourceKey)),"source_version":\(version),"size_bytes":\(size.map(String.init) ?? "null"),"mtime_ns":\(mtime.map(String.init) ?? "null"),"resource_identity_kind":\(jsonString(kind)),"resource_identity_value":\(jsonString(identity)),"provider_version":\(jsonString(providerVersion)),"sha256":\(jsonString(sha256))}
            """
        return sourceHex(SHA256.hash(data: Data(json.utf8)))
    }
}
