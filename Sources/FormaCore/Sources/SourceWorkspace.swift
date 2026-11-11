import Darwin
import Foundation
import GRDB
import Security

public actor SourceWorkspace {
    private let store: SourceStore
    private var scanInProgress = false
    private var readInProgress = false

    public init(databaseURL: URL) throws {
        store = try SourceStore(url: databaseURL)
    }

    public func register(_ url: URL) throws -> SourceScope {
        guard !scanInProgress, !readInProgress else { throw FormaError.unavailable }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let selected = try SourceRootAccess(url)
        return try store.database.write { db in
            try Self.register(selected, authorizedURL: url, in: db)
        }
    }

    public func scopes() throws -> [SourceScope] {
        try store.database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source_scopes ORDER BY rowid").map { try SourceStore.scope($0) }
        }
    }

    public func listing(_ scope: SourceScope) throws -> SourceListing {
        try store.database.read { db in
            let current = try SourceStore.scope(db, id: scope.id)
            guard current.rootID == scope.rootID else { throw FormaError.invalidSource }
            return try SourceStore.listing(db, scope: current)
        }
    }

    public func scan(_ scope: SourceScope) async throws -> SourceListing {
        guard !scanInProgress, !readInProgress else { throw FormaError.unavailable }
        let (current, root) = try scanConfiguration(scope)
        let scanID = UUID()
        try beginScan(scanID, scope: current)
        scanInProgress = true
        defer { scanInProgress = false }
        let work = Task.detached(priority: .utility) { () throws -> SourceScanResult in
            try Task.checkCancellation()
            do {
                return try root.withAccess { access in
                    if access.metadata.isHydrationPending {
                        return SourceScanResult(issues: [.init(relativePath: current.relativePath, reason: .hydrationPending)])
                    }
                    do {
                        return try SourceFileScanner.collect(root: access, path: current.relativePath)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return SourceScanResult(issues: [.init(relativePath: current.relativePath, reason: .unreadable)])
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return SourceScanResult(issues: [.init(relativePath: current.relativePath, reason: .authorization)])
            }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            return try commitScan(result, scope: current, root: root, scanID: scanID)
        } catch is CancellationError {
            try finishScan(scanID, state: .cancelled)
            throw CancellationError()
        } catch {
            try finishScan(scanID, state: .incomplete)
            throw error
        }
    }

    public func evidence(for entry: SourceEntry) async throws -> SourceEvidence {
        try await read(entry, extracting: true)
    }

    /// Streams any regular local file using bounded memory, without extracting its contents.
    public func hash(for entry: SourceEntry) async throws -> SourceEvidence {
        try await read(entry, extracting: false)
    }

    private func read(_ entry: SourceEntry, extracting: Bool) async throws -> SourceEvidence {
        guard !readInProgress, !scanInProgress else { throw FormaError.unavailable }
        let (stored, root) = try evidenceConfiguration(entry)
        guard stored.entry.snapshotFingerprint == entry.snapshotFingerprint,
              SourcePath.sameSpelling(stored.entry.relativePath, entry.relativePath) else {
            return .init(entry: stored.entry, status: .changedDuringRead, items: [], sha256: nil)
        }
        guard stored.entry.state == .present else {
            return .init(entry: stored.entry, status: .unavailable, items: [], sha256: nil)
        }
        readInProgress = true
        defer { readInProgress = false }
        let work = Task.detached(priority: .utility) {
            try SourceEvidenceReader.capture(stored, root: root, extracting: extracting)
        }
        let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        return try commitEvidence(result, previous: stored)
    }

    private func scanConfiguration(_ scope: SourceScope) throws -> (SourceScope, StoredSourceRoot) {
        try store.database.read { db in
            let current = try SourceStore.scope(db, id: scope.id)
            guard current.rootID == scope.rootID else { throw FormaError.invalidSource }
            return (current, try SourceStore.root(db, id: current.rootID))
        }
    }

    private func beginScan(_ id: UUID, scope: SourceScope) throws {
        try store.database.write { db in
            try db.execute(sql: "INSERT INTO scans(id, scope_id, started_at, state) VALUES (?, ?, ?, 'scanning')",
                           arguments: [id.sourceKey, scope.id.sourceKey, Date().timeIntervalSince1970])
        }
    }

    private func commitScan(_ result: SourceScanResult, scope: SourceScope, root: StoredSourceRoot,
                            scanID: UUID) throws -> SourceListing {
        try store.database.write { db in try Self.publish(result, scope: scope, root: root, scanID: scanID, in: db) }
    }

    private func finishScan(_ id: UUID, state: SourceScanState) throws {
        try store.database.write { db in try SourceStore.finishScan(db, id: id, state: state) }
    }

    private func evidenceConfiguration(_ entry: SourceEntry) throws -> (StoredSourceEntry, StoredSourceRoot) {
        try store.database.read { db in
            let stored = try SourceStore.entry(db, id: entry.id)
            guard stored.entry.rootID == entry.rootID else { throw FormaError.invalidSource }
            return (stored, try SourceStore.root(db, id: entry.rootID))
        }
    }

    private func commitEvidence(_ result: SourceEvidenceCapture, previous: StoredSourceEntry) throws -> SourceEvidence {
        try store.database.write { db in try Self.publishEvidence(result, previous: previous, in: db) }
    }
}

extension SourceWorkspace {
    private static func register(_ selected: SourceRootAccess, authorizedURL: URL, in db: Database) throws -> SourceScope {
        let roots = try Row.fetchAll(db, sql: "SELECT * FROM source_roots ORDER BY rowid").map(StoredSourceRoot.init)
        if let same = roots.first(where: { $0.identity == selected.rootIdentity }) {
            guard same.caseSensitive == selected.caseSensitive else { throw FormaError.invalidSource }
            try updateBookmark(in: db, id: same.id, selected: selected, authorizedURL: authorizedURL, insert: false)
            return try findOrInsertScope(db, root: same.id, relative: "", normalized: "", name: selected.url.lastPathComponent)
        }
        var childRoots: [(StoredSourceRoot, String)] = []
        var parentRoot: (StoredSourceRoot, String)?
        for root in roots {
            do {
                try root.withAccess { existing in
                    if let relative = try relative(selected, below: existing) {
                        guard parentRoot == nil else { throw FormaError.invalidSource }
                        parentRoot = (root, relative)
                    } else if let relative = try relative(existing, below: selected) {
                        childRoots.append((root, relative))
                    } else if pathOverlap(existing.url.path, selected.url.path) {
                        throw FormaError.invalidSource
                    }
                }
            } catch {
                // The last path is used only to detect a possible overlap with an unresolved grant.
                if pathOverlap(root.lastPath, selected.url.path) || (error as? FormaError) == .invalidSource {
                    throw FormaError.invalidSource
                }
            }
        }
        if let (root, relative) = parentRoot {
            guard childRoots.isEmpty, let caseSensitive = root.caseSensitive else { throw FormaError.invalidSource }
            return try findOrInsertScope(db, root: root.id, relative: relative,
                                         normalized: SourcePath.normalize(relative, caseSensitive: caseSensitive),
                                         name: selected.url.lastPathComponent)
        }
        if let (root, prefix) = childRoots.first {
            // A single previously registered child keeps its canonical ID. Rebase paths and
            // preserve its scope, logical file IDs and immutable snapshot history.
            guard childRoots.count == 1, let caseSensitive = root.caseSensitive,
                  selected.caseSensitive == caseSensitive else { throw FormaError.invalidSource }
            try rebase(db, root: root.id, prefix: prefix, caseSensitive: caseSensitive)
            try updateBookmark(in: db, id: root.id, selected: selected, authorizedURL: authorizedURL, insert: false)
            return try findOrInsertScope(db, root: root.id, relative: "", normalized: "", name: selected.url.lastPathComponent)
        }
        let id = UUID()
        try updateBookmark(in: db, id: id, selected: selected, authorizedURL: authorizedURL, insert: true)
        return try findOrInsertScope(db, root: id, relative: "", normalized: "", name: selected.url.lastPathComponent)
    }

    private static func relative(_ child: SourceRootAccess, below ancestor: SourceRootAccess) throws -> String? {
        guard child.metadata.device == ancestor.metadata.device, let caseSensitive = ancestor.caseSensitive else { return nil }
        let parentComponents = ancestor.url.pathComponents
        let childComponents = child.url.pathComponents
        guard childComponents.count > parentComponents.count else { return nil }
        let parentPath = parentComponents.dropFirst().joined(separator: "/")
        let prefix = childComponents.dropFirst().prefix(parentComponents.count - 1).joined(separator: "/")
        guard try SourcePath.normalize(parentPath, caseSensitive: caseSensitive)
            == SourcePath.normalize(prefix, caseSensitive: caseSensitive) else { return nil }
        let relative = childComponents.dropFirst(parentComponents.count).joined(separator: "/")
        let descriptor = try ancestor.openDirectory(relative)
        defer { close(descriptor) }
        guard try SourceFileMetadata.read(descriptor: descriptor).objectKey == child.metadata.objectKey else {
            throw FormaError.invalidSource
        }
        return relative
    }

    private static func pathOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.precomposedStringWithCanonicalMapping.lowercased()
        let b = rhs.precomposedStringWithCanonicalMapping.lowercased()
        return a == "/" || b == "/" || SourcePath.contains(a, in: b) || SourcePath.contains(b, in: a)
    }

    private static func updateBookmark(in db: Database, id: UUID, selected: SourceRootAccess,
                                       authorizedURL: URL, insert: Bool) throws {
        let bookmark: Data
        let securityScoped: Bool
        do {
            bookmark = try authorizedURL.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
            securityScoped = true
        } catch {
            // An unsandboxed developer executable may lack the entitlement to create a scoped
            // bookmark. Ordinary bookmarks resolve there using its existing filesystem rights.
            if let task = SecTaskCreateFromSelf(nil),
               SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool == true {
                throw FormaError.unauthorized
            }
            bookmark = try authorizedURL.bookmarkData()
            securityScoped = false
        }
        if insert {
            try db.execute(sql: """
                INSERT INTO source_roots(id, bookmark, security_scoped, resource_identity, last_path, case_sensitive)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id.sourceKey, bookmark, securityScoped, selected.rootIdentity, selected.url.path,
                                  selected.caseSensitive])
        } else {
            try db.execute(sql: """
                UPDATE source_roots SET bookmark = ?, security_scoped = ?, resource_identity = ?, last_path = ?,
                    case_sensitive = ? WHERE id = ?
                """, arguments: [bookmark, securityScoped, selected.rootIdentity, selected.url.path,
                                  selected.caseSensitive, id.sourceKey])
        }
    }

    private static func findOrInsertScope(_ db: Database, root: UUID, relative: String,
                                          normalized: String, name: String) throws -> SourceScope {
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM source_scopes WHERE root_id = ? AND normalized_path = ?",
                                      arguments: [root.sourceKey, normalized]) {
            return try SourceStore.scope(row)
        }
        let id = UUID()
        try db.execute(sql: "INSERT INTO source_scopes VALUES (?, ?, ?, ?, ?)",
                       arguments: [id.sourceKey, root.sourceKey, relative, normalized, name])
        return .init(id: id, rootID: root, relativePath: relative, displayName: name)
    }

    private static func rebase(_ db: Database, root: UUID, prefix: String, caseSensitive: Bool) throws {
        let entries = try SourceStore.entries(db, root: root)
        let scopes = try Row.fetchAll(db, sql: "SELECT * FROM source_scopes WHERE root_id = ?",
                                      arguments: [root.sourceKey]).map { try SourceStore.scope($0) }
        // Move all normalized paths out of the relative namespace before applying the prefix.
        try db.execute(sql: "UPDATE source_entries SET normalized_path = '/' || normalized_path WHERE root_id = ?",
                       arguments: [root.sourceKey])
        try db.execute(sql: "UPDATE source_scopes SET normalized_path = '/' || normalized_path WHERE root_id = ?",
                       arguments: [root.sourceKey])
        for stored in entries {
            let entry = stored.entry
            let relative = SourcePath.join(prefix, entry.relativePath)
            try db.execute(sql: "UPDATE source_entries SET relative_path = ?, normalized_path = ? WHERE id = ?",
                           arguments: [relative, try SourcePath.normalize(relative, caseSensitive: caseSensitive), entry.id.sourceKey])
            try SourceStore.pathHistory(db, id: entry.id, scanID: nil, from: entry.relativePath, to: relative)
        }
        for scope in scopes {
            let relative = SourcePath.join(prefix, scope.relativePath)
            try db.execute(sql: "UPDATE source_scopes SET relative_path = ?, normalized_path = ? WHERE id = ?",
                           arguments: [relative, try SourcePath.normalize(relative, caseSensitive: caseSensitive), scope.id.sourceKey])
        }
    }
}
