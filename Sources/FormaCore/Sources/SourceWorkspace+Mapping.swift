import Foundation
import GRDB

/// Mapping-layer persistence on the one actor that owns the workspace database.
///
/// PLAN §10.2 keeps a single writer for state that later drives side effects, so
/// the context, evidence registry, manifests and run records all go through
/// `SourceWorkspace` rather than opening a second connection. These methods
/// store and read what the mapping layer computed; none of them decides
/// anything, and none of them can reach a DEVONthink client.
extension SourceWorkspace {
    /// Builds the two-phase context for a scope and stores it as a new revision
    /// only when the inputs actually changed. An unchanged rescan therefore
    /// reuses the stored revision instead of minting a new one.
    public func buildContext(scope: SourceScope, profile: MappingProfile,
                             history: [ContextHistoryMatch] = []) async throws -> ProjectContext {
        let listing = try listing(scope)
        let digest = ContextBuilder.inputDigest(scopeID: scope.id, profile: profile, entries: listing.entries)
        if let stored = try await storedContext(scope: scope, profile: profile, inputDigest: digest) {
            return stored
        }
        let revision = try await store.database.read { db in
            try MappingStore.nextContextRevision(scopeID: scope.id, profile: profile, in: db)
        }
        let context = ContextBuilder.build(
            ContextBuilderInput(scopeID: scope.id, profile: profile, entries: listing.entries, history: history),
            revision: revision
        )
        try await store.database.write { db in
            try MappingStore.insertContext(context, scopeID: scope.id, in: db)
        }
        return context
    }

    public func storedContext(scope: SourceScope, profile: MappingProfile, inputDigest: String) async throws
        -> ProjectContext?
    {
        try await store.database.read { db in
            try MappingStore.currentContext(scopeID: scope.id, profile: profile, inputDigest: inputDigest, in: db)
        }
    }

    public func storedContext(scope: SourceScope, profile: MappingProfile, revision: Int) async throws
        -> ProjectContext?
    {
        try await store.database.read { db in
            try MappingStore.context(scopeID: scope.id, profile: profile, revision: revision, in: db)
        }
    }

    /// Registers evidence for a source. Earlier rows stay: they are what an
    /// older manifest revision was decided from, and deleting them would break
    /// the foreign key those revisions rely on.
    public func recordEvidence(_ records: [EvidenceRecord], for sourceID: UUID) async throws {
        try await store.database.write { db in try MappingStore.recordEvidence(records, in: db) }
    }

    /// Every row registered for a source, including superseded snapshots.
    public func evidenceRegistry(for sourceID: UUID) async throws -> [EvidenceRecord] {
        try await store.database.read { db in try MappingStore.evidence(for: sourceID, in: db) }
    }

    /// The rows that describe the file at one snapshot revision: what a mapping
    /// request may cite.
    public func evidenceRegistry(for sourceID: UUID, snapshotRevision: Int) async throws -> [EvidenceRecord] {
        try await store.database.read { db in
            try MappingStore.evidence(for: sourceID, snapshotRevision: snapshotRevision, in: db)
        }
    }

    /// Reads a file and registers what was observed, returning the rows a
    /// mapping request may cite.
    ///
    /// The capture carries the entry as it exists *after* the read: when the
    /// content moved, the workspace appends a new snapshot revision, and
    /// registering the fresh excerpt under the caller's older revision would
    /// leave no evidence row at the current revision at all. Every later
    /// manifest for that file would then fail its own citation check and could
    /// never be stored.
    public func captureEvidence(for entry: SourceEntry) async throws -> [EvidenceRecord] {
        let capture = try await evidence(for: entry)
        let records = try EvidenceRegistry.records(for: capture.entry, capture: capture)
        try await recordEvidence(records, for: capture.entry.id)
        return records
    }

    /// Capturing a batch is all-or-nothing on cancellation: a partial result is
    /// indistinguishable from "these files have no evidence", so cancellation
    /// propagates instead of returning a half set.
    public func captureEvidence(for entries: [SourceEntry]) async throws -> [UUID: [EvidenceRecord]] {
        var result: [UUID: [EvidenceRecord]] = [:]
        for entry in entries {
            try Task.checkCancellation()
            result[entry.id] = try await captureEvidence(for: entry)
        }
        return result
    }

    /// Stores a manifest as the next revision. A caller cannot overwrite an
    /// existing revision by handing it the same number: the store decides.
    public func saveManifest(_ manifest: Manifest, scopeID: UUID) async throws -> Manifest {
        try await store.database.write { db in
            let revision = try MappingStore.nextManifestRevision(manifestID: manifest.envelope.manifestID, in: db)
            let stored = Manifest(envelope: manifest.envelope.rebased(to: revision), entries: manifest.entries,
                                  report: manifest.report)
            // `manifest_entry_evidence.evidence_id` carries a foreign key into
            // `evidence_items`, so citing an unregistered row fails here rather
            // than being discovered by re-querying after the fact.
            try MappingStore.insertManifest(stored, scopeID: scopeID, in: db)
            return stored
        }
    }

    public func currentManifest(scope: SourceScope, profile: MappingProfile) async throws -> Manifest? {
        try await store.database.read { db in
            try MappingStore.latestManifest(scopeID: scope.id, profile: profile, in: db)
        }
    }

    /// Invalidates exactly the entries whose facts moved, and reports whether
    /// the rest may still be reused.
    public func reconcile(scope: SourceScope, profile: MappingProfile) async throws
        -> ManifestReconciler.Decision?
    {
        guard let manifest = try await currentManifest(scope: scope, profile: profile) else { return nil }
        let listing = try listing(scope)
        let digest = ContextBuilder.inputDigest(scopeID: scope.id, profile: profile, entries: listing.entries)
        let context = try await storedContext(scope: scope, profile: profile, inputDigest: digest)
            ?? ContextBuilder.build(ContextBuilderInput(scopeID: scope.id, profile: profile,
                                                        entries: listing.entries),
                                    revision: manifest.envelope.contextRevision)
        let previous = try await storedContext(scope: scope, profile: profile,
                                               revision: manifest.envelope.contextRevision)
        let computed = ManifestReconciler.decide(manifest: manifest, currentEntries: listing.entries,
                                                 previousContext: previous, currentContext: context)
        // An entry that is already invalidated stays invalidated. Reporting it
        // again would make a no-op rescan look like fresh damage and would hide
        // whether anything actually moved since the last reconciliation.
        let already = Set(manifest.entries.filter { $0.state == .invalidated }.map { $0.sourceID })
        let fresh = computed.invalidatedSourceIDs.subtracting(already)
        let reason = fresh.isEmpty ? "already_invalidated"
            : fresh == computed.invalidatedSourceIDs ? computed.reason : "\(computed.reason)_partially"
        let decision = ManifestReconciler.Decision(invalidatedSourceIDs: fresh, reason: reason)
        guard !decision.invalidatedSourceIDs.isEmpty else { return decision }
        let invalidated = decision.invalidatedSourceIDs
        let why = decision.reason
        try await store.database.write { db in
            try MappingStore.invalidate(manifestID: manifest.envelope.manifestID,
                                        revision: manifest.envelope.revision,
                                        sourceIDs: invalidated, reason: why, in: db)
        }
        return decision
    }

    public func startMappingRun(_ run: MappingRun) async throws {
        try await store.database.write { db in try MappingStore.startRun(run, in: db) }
    }

    public func finishMappingRun(id: UUID, state: MappingRun.State, batches: Int, error: FormaError?) async throws {
        try await store.database.write { db in
            try MappingStore.finishRun(id: id, state: state, batches: batches, error: error, finishedAt: .now,
                                       in: db)
        }
    }

    public func recordProviderCall(_ call: ProviderCall) async throws {
        try await store.database.write { db in try MappingStore.recordProviderCall(call, in: db) }
    }

    public func providerCalls(runID: UUID) async throws -> [ProviderCall] {
        try await store.database.read { db in try MappingStore.providerCalls(runID: runID, in: db) }
    }
}
