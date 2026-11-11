import Foundation

/// Decides which stored manifest revisions a change in the workspace has
/// invalidated, and how far that reaches.
///
/// PLAN §7.3: an invalidated revision keeps its original decision state for
/// audit, and only entries that actually depended on what changed are touched.
public enum ManifestReconciler {
    public struct Decision: Sendable, Equatable {
        public let invalidatedSourceIDs: Set<UUID>
        public let reason: String
        /// True when the remaining entries may be reused as they are, which is
        /// what keeps a rescan from re-billing a whole archive.
        public let reusable: Bool
    }

    public static func decide(manifest: Manifest, currentEntries: [SourceEntry], currentContext: ProjectContext)
        -> Decision
    {
        let byID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        var stale: Set<UUID> = []
        for entry in manifest.entries {
            guard let current = byID[entry.sourceID] else {
                stale.insert(entry.sourceID)
                continue
            }
            if current.snapshotFingerprint != entry.snapshotFingerprint
                || Int(current.snapshotRevision) != entry.snapshotRevision {
                stale.insert(entry.sourceID)
            }
        }
        let contextMoved = manifest.entries.contains { entry in
            !currentContext.candidate(for: entry.sourceID).isEmpty
        } && currentContext.revision != manifest.envelope.contextRevision
        if contextMoved {
            // Only the files whose membership actually changed: an unrelated
            // project directory must not invalidate this one's decisions.
            stale.formUnion(currentContext.candidates.flatMap { candidate in
                candidate.memberSourceIDs
            }.filter { source in
                guard let before = manifest.entry(for: source) else { return false }
                return currentContext.conflictedSourceIDs.contains(source)
                    || before.state == .invalidated
            })
        }
        if !stale.isEmpty {
            return Decision(invalidatedSourceIDs: stale,
                            reason: contextMoved ? "context_or_snapshot_changed" : "snapshot_changed",
                            reusable: stale.count < manifest.entries.count)
        }
        return Decision(invalidatedSourceIDs: [], reason: "unchanged", reusable: true)
    }
}
