import Foundation
import GRDB

extension SourceWorkspace {
    static func publish(_ result: SourceScanResult, scope: SourceScope, root: StoredSourceRoot,
                        scanID: UUID, in db: Database) throws -> SourceListing {
        let previous = try SourceStore.entries(db, root: root.id)
        let byPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.entry.normalizedRelativePath, $0) })
        let seen = Set(result.records.map(\.normalizedPath))
        let oldIdentities = Dictionary(grouping: previous.compactMap { stored in
            stored.stableIdentity.map { ($0, stored) }
        }, by: \.0)
        let newIdentities = Dictionary(grouping: result.records.compactMap(\.stableIdentity), by: { $0 })
        var used = Set<UUID>()
        let issues = result.issues
        var additions: [(UUID, SourceScanRecord)] = []
        var stats = [String: Int]()
        var fileCount = 0
        var bytes: Int64 = 0
        func collides(_ path: String) -> Bool {
            result.collisionPaths.contains { SourcePath.contains(path, in: $0) }
        }
        let allowMoves = issues.isEmpty && scope.relativePath.isEmpty
        for record in result.records {
            let path = record.normalizedPath
            guard !collides(path) else { continue }
            // One registered relative path keeps its own source_id even when only the
            // spelling differs: on a case- or Unicode-insensitive volume the folded path
            // is the same registered location, so `update` records the new spelling in
            // path_history and refreshes the snapshot instead of orphaning the file.
            // Distinct names that fold to one path inside a single scan are the scanner's
            // collisionPaths, and those are held below without being folded.
            var stored = byPath[path]
            // A move is only adopted when one previous entry and one current record share
            // one stable identity, the previous path has disappeared from this scan, and
            // that entry is still a live presence. An entry already held for ambiguity or
            // recorded missing must not be resurrected by an identity match alone.
            if stored == nil, allowMoves, let identity = record.stableIdentity,
               let old = oldIdentities[identity], old.count == 1, old[0].1.entry.state == .present,
               newIdentities[identity]?.count == 1,
               !seen.contains(old[0].1.entry.normalizedRelativePath),
               !collides(old[0].1.entry.normalizedRelativePath) {
                stored = old[0].1
            }
            if let stored {
                try update(stored, from: record, scanID: scanID, in: db)
                used.insert(stored.entry.id)
            } else {
                additions.append((try insert(record, root: root.id, scanID: scanID, in: db), record))
            }
            if record.metadata.isRegular {
                fileCount += 1
                let (total, overflow) = bytes.addingReportingOverflow(record.metadata.sizeBytes)
                bytes = overflow ? .max : total
                stats[(record.relativePath as NSString).pathExtension.lowercased(), default: 0] += 1
            }
        }
        let completeRoot = issues.isEmpty && scope.relativePath.isEmpty
        var unseenByObject: [String: [UUID]] = [:]
        for stored in previous where !used.contains(stored.entry.id) {
            if collides(stored.entry.normalizedRelativePath) {
                try mark(stored, state: .held, scanID: scanID, in: db)
            } else if completeRoot {
                try mark(stored, state: .missing, scanID: scanID, in: db)
                if let objectKey = stored.objectKey {
                    unseenByObject[objectKey, default: []].append(stored.entry.id)
                }
            }
        }
        for (newID, record) in additions where record.metadata.isRegular {
            for oldID in unseenByObject[record.metadata.objectKey] ?? [] {
                try db.execute(sql: "INSERT OR IGNORE INTO source_move_candidates VALUES (?, ?, 'local-object-observation')",
                               arguments: [oldID.sourceKey, newID.sourceKey])
            }
        }
        let statistics = SourceScanStatistics(directoryCount: result.directories.count { !collides($0) },
                                              fileCount: fileCount, sizeBytes: bytes, extensions: stats)
        try SourceStore.finishScan(db, id: scanID, state: issues.isEmpty ? .complete : .incomplete,
                                   issues: issues, statistics: statistics)
        return try SourceStore.listing(db, scope: scope)
    }

    private static func insert(_ record: SourceScanRecord, root: UUID, scanID: UUID, in db: Database) throws -> UUID {
        let id = UUID()
        let metadata = record.metadata
        try db.execute(sql: """
            INSERT INTO source_entries(id, root_id, relative_path, normalized_path, state, hydration_pending, provider,
                object_key, file_type, change_ns, current_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            """, arguments: [id.sourceKey, root.sourceKey, record.relativePath, record.normalizedPath, record.state.rawValue,
                              metadata.isHydrationPending, record.provider.rawValue, metadata.objectKey, metadata.fileType,
                              metadata.changedNanoseconds])
        try SourceStore.appendSnapshot(db, id: id, revision: 1, version: 1, scanID: scanID, size: metadata.sizeBytes,
                                       mtime: metadata.modifiedNanoseconds, identity: record.stableIdentity, sha256: nil)
        try SourceStore.pathHistory(db, id: id, scanID: scanID, from: nil, to: record.relativePath)
        return id
    }

    private static func update(_ stored: StoredSourceEntry, from record: SourceScanRecord, scanID: UUID,
                               in db: Database) throws {
        let entry = stored.entry
        let metadata = record.metadata
        let moved = !SourcePath.sameSpelling(entry.relativePath, record.relativePath)
        let ctimeChanged = !moved && !entry.hydrationPending && !metadata.isHydrationPending
            && stored.changeNanoseconds != metadata.changedNanoseconds
        let changed = entry.state != record.state || ctimeChanged
            || !stored.matches(metadata, stableIdentity: record.stableIdentity)
        let identity = changed ? record.stableIdentity : (record.stableIdentity ?? stored.stableIdentity)
        let revisionChanged = changed || identity != stored.stableIdentity
        let revision = entry.snapshotRevision + (revisionChanged ? 1 : 0)
        if revisionChanged {
            try SourceStore.appendSnapshot(db, id: entry.id, revision: revision, version: entry.sourceVersion + (changed ? 1 : 0),
                                           scanID: scanID, size: metadata.sizeBytes, mtime: metadata.modifiedNanoseconds,
                                           identity: identity, sha256: changed ? nil : entry.sha256)
        }
        if moved {
            try SourceStore.pathHistory(db, id: entry.id, scanID: scanID, from: entry.relativePath, to: record.relativePath)
        }
        if revisionChanged || moved || entry.hydrationPending != metadata.isHydrationPending
            || entry.provider != record.provider || stored.objectKey != metadata.objectKey
            || stored.changeNanoseconds != metadata.changedNanoseconds {
            try db.execute(sql: """
                UPDATE source_entries SET relative_path = ?, normalized_path = ?, state = ?, hydration_pending = ?,
                    provider = ?, object_key = ?, file_type = ?, change_ns = ?, current_revision = ? WHERE id = ?
                """, arguments: [record.relativePath, record.normalizedPath, record.state.rawValue, metadata.isHydrationPending,
                                  record.provider.rawValue, metadata.objectKey, metadata.fileType, metadata.changedNanoseconds,
                                  revision, entry.id.sourceKey])
        }
    }

    private static func mark(_ stored: StoredSourceEntry, state: SourceEntryState, scanID: UUID, in db: Database) throws {
        let entry = stored.entry
        guard entry.state != state else { return }
        let revision = entry.snapshotRevision + 1
        try SourceStore.appendSnapshot(db, id: entry.id, revision: revision, version: entry.sourceVersion + 1, scanID: scanID,
                                       size: entry.sizeBytes, mtime: entry.modificationTimeNanoseconds,
                                       identity: stored.stableIdentity, sha256: nil)
        try db.execute(sql: "UPDATE source_entries SET state = ?, current_revision = ? WHERE id = ?",
                       arguments: [state.rawValue, revision, entry.id.sourceKey])
    }

    static func publishEvidence(_ result: SourceEvidenceCapture, previous: StoredSourceEntry, in db: Database) throws -> SourceEvidence {
        let stored = try SourceStore.entry(db, id: previous.entry.id)
        let entry = stored.entry
        guard entry.state == .present, entry.snapshotFingerprint == previous.entry.snapshotFingerprint,
              SourcePath.sameSpelling(entry.relativePath, previous.entry.relativePath) else {
            return .init(entry: entry, status: .changedDuringRead, items: [], sha256: nil)
        }
        let changed = result.status == .changedDuringRead || (entry.sha256 != nil && result.sha256 != nil && entry.sha256 != result.sha256)
        let identity = changed ? result.stableIdentity : (result.stableIdentity ?? stored.stableIdentity)
        let hydrate = result.status == .hydrationPending || result.metadata?.isHydrationPending == true
        if changed || (result.sha256 != nil && result.sha256 != entry.sha256) || identity != stored.stableIdentity {
            let revision = entry.snapshotRevision + 1
            try SourceStore.appendSnapshot(db, id: entry.id, revision: revision, version: entry.sourceVersion + (changed ? 1 : 0),
                                           scanID: nil, size: result.metadata?.sizeBytes ?? entry.sizeBytes,
                                           mtime: result.metadata?.modifiedNanoseconds ?? entry.modificationTimeNanoseconds,
                                           identity: identity, sha256: result.sha256)
            try db.execute(sql: """
                UPDATE source_entries SET current_revision = ?, hydration_pending = ?, object_key = ?, file_type = ?,
                    change_ns = ? WHERE id = ?
                """, arguments: [revision, hydrate, result.metadata?.objectKey ?? stored.objectKey,
                                  result.metadata?.fileType ?? stored.fileType,
                                  result.metadata?.changedNanoseconds ?? stored.changeNanoseconds, entry.id.sourceKey])
            if let sha = result.sha256 {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO source_move_candidates(previous_id, candidate_id, reason)
                    SELECT e.id, ?, 'equal-sha256' FROM source_entries e
                    WHERE e.root_id = ? AND e.state = 'missing' AND e.id <> ? AND ? = (
                        SELECT s.sha256 FROM source_snapshots s WHERE s.source_id = e.id AND s.sha256 IS NOT NULL
                        ORDER BY s.revision DESC LIMIT 1
                    )
                    """, arguments: [entry.id.sourceKey, entry.rootID.sourceKey, entry.id.sourceKey, sha])
            }
        } else if (result.metadata != nil || hydrate), entry.hydrationPending != hydrate {
            try db.execute(sql: "UPDATE source_entries SET hydration_pending = ?, object_key = ?, change_ns = ? WHERE id = ?",
                           arguments: [hydrate, result.metadata?.objectKey ?? stored.objectKey,
                                       result.metadata?.changedNanoseconds ?? stored.changeNanoseconds, entry.id.sourceKey])
        }
        return .init(entry: try SourceStore.entry(db, id: entry.id).entry,
                     status: result.status, items: result.items, sha256: result.sha256)
    }
}
