import Foundation

/// Decides which stored manifest revisions a change in the workspace has
/// invalidated, and how far that reaches.
///
/// PLAN §7.3: an invalidated revision keeps its original decision state for
/// audit, and only entries that actually depended on what changed are touched.
public enum ManifestReconciler {
    public struct Decision: Sendable, Equatable {
        public let invalidatedSourceIDs: Set<UUID>
        /// Which rule produced the decision, in the vocabulary the Exceptions
        /// view and the exported bundle show.
        public let reason: String
    }

    /// Compares a stored manifest against the current listing and the current
    /// context.
    ///
    /// `previousContext` is the stored context revision the manifest cites.
    /// Without it a rebuild of the context could not be distinguished from a
    /// change of membership, and every entry would be re-mapped because one
    /// unrelated directory moved.
    public static func decide(manifest: Manifest, currentEntries: [SourceEntry], previousContext: ProjectContext?,
                              currentContext: ProjectContext) -> Decision {
        let byID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        var stale: Set<UUID> = []
        var snapshotChanged = false
        for entry in manifest.entries {
            guard let current = byID[entry.sourceID] else {
                stale.insert(entry.sourceID)
                continue
            }
            if current.snapshotFingerprint != entry.snapshotFingerprint
                || Int(current.snapshotRevision) != entry.snapshotRevision {
                stale.insert(entry.sourceID)
                snapshotChanged = true
            }
        }
        var membershipChanged = false
        if let previousContext, previousContext.revision != currentContext.revision {
            // Membership, not the mere existence of a newer context revision,
            // is what invalidates a decision.
            let moved = ContextBuilder.affectedSourceIDs(between: previousContext, and: currentContext)
                .intersection(Set(manifest.entries.map(\.sourceID)))
            if !moved.isEmpty {
                stale.formUnion(moved)
                membershipChanged = true
            }
        }
        guard !stale.isEmpty else { return Decision(invalidatedSourceIDs: [], reason: "unchanged") }
        // The most specific reason wins, because the recovery path differs: a
        // membership change needs the affected cluster re-mapped, while a
        // snapshot change needs the file re-read first.
        let reason = membershipChanged && snapshotChanged ? "membership_and_snapshot_changed"
            : membershipChanged ? "membership_changed" : snapshotChanged ? "snapshot_changed" : "source_missing"
        return Decision(invalidatedSourceIDs: stale, reason: reason)
    }
}
