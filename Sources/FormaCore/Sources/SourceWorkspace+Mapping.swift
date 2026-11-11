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
        // The parameter is the caller's claim about which file these rows
        // describe. Rows carry their own source, so a mismatch means the caller
        // is holding a stale entry: registering such rows under a different
        // source than the caller asked for would make the registry answer an
        // empty set for that source and silently push fields back to unknown.
        guard records.allSatisfy({ $0.sourceID == sourceID }) else { throw FormaError.invalidSource }
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

    /// Every registered row for a set of sources, in one read.
    ///
    /// A caller that has to describe a batch - the privacy preview - needs the
    /// rows for every file in it. Asking per file turned one reviewer action
    /// into a query for each file, and a preview assembled from whatever a
    /// session happened to open earlier describes a request the run would not
    /// make.
    public func registeredEvidence(for sourceIDs: Set<UUID>) async throws -> [UUID: [EvidenceRecord]] {
        guard !sourceIDs.isEmpty else { return [:] }
        return try await store.database.read { db in
            try MappingStore.evidence(for: sourceIDs, in: db)
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
        try await store.database.write { db in try Self.persist(manifest, scopeID: scopeID, in: db) }
    }

    /// Writes the next revision inside the caller's transaction.
    ///
    /// Split from `saveManifest` because a correction has two facts to record -
    /// the version and the decision that produced it - and they must not be
    /// separable on disk.
    private static func persist(_ manifest: Manifest, scopeID: UUID, in db: Database) throws -> Manifest {
        let revision = try MappingStore.nextManifestRevision(manifestID: manifest.envelope.manifestID, in: db)
        let stored = Manifest(envelope: manifest.envelope.rebased(to: revision), entries: manifest.entries,
                              report: manifest.report)
        // `manifest_entry_evidence.evidence_id` carries a foreign key into
        // `evidence_items`, so citing an unregistered row fails here rather
        // than being discovered by re-querying after the fact.
        try MappingStore.insertManifest(stored, scopeID: scopeID, in: db)
        return stored
    }

    public func currentManifest(scope: SourceScope, profile: MappingProfile) async throws -> Manifest? {
        try await store.database.read { db in
            try MappingStore.latestManifest(scopeID: scope.id, profile: profile, in: db)
        }
    }

    /// Invalidates exactly the entries whose facts moved.
    ///
    /// A context that does not match the current structure is rebuilt and
    /// stored under a fresh revision first: comparing a stored manifest
    /// against an in-memory rebuild that reused the manifest's own revision
    /// number would make the membership branch unreachable, because the two
    /// contexts would compare as equal by revision while differing in content.
    public func reconcile(scope: SourceScope, profile: MappingProfile) async throws
        -> ManifestReconciler.Decision?
    {
        guard let manifest = try await currentManifest(scope: scope, profile: profile) else { return nil }
        let listing = try listing(scope)
        let context = try await buildContext(scope: scope, profile: profile)
        let previous = try await storedContext(scope: scope, profile: profile,
                                               revision: manifest.envelope.contextRevision)
        let computed = ManifestReconciler.decide(manifest: manifest, currentEntries: listing.entries,
                                                 previousContext: previous, currentContext: context)
        // An entry that is already invalidated stays invalidated. Reporting it
        // again would make a no-op rescan look like fresh damage and would hide
        // whether anything actually moved since the last reconciliation.
        let already = Set(manifest.entries.filter { $0.state == .invalidated }.map { $0.sourceID })
        let fresh = computed.invalidatedSourceIDs.subtracting(already)
        // Three distinct outcomes, and they must not be conflated: nothing
        // moved, something moved that was already reported, and something
        // genuinely new.
        let reason: String
        if computed.invalidatedSourceIDs.isEmpty {
            reason = computed.reason
        } else if fresh.isEmpty {
            reason = "already_invalidated"
        } else if fresh == computed.invalidatedSourceIDs {
            reason = computed.reason
        } else {
            reason = "\(computed.reason)_partially"
        }
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

    /// Applies a human correction and stores what it produced.
    ///
    /// The engine decides; this method gathers the facts it needs - the current
    /// listing, the context revision the manifest cites, the registered rows it
    /// may cite - and persists the outcome. A refused attempt is stored and
    /// changes no revision, so the review screen can show the click while the
    /// version history keeps only decisions actually made. Publishing goes
    /// through `persist`, so a citation's foreign key into `evidence_items` is
    /// enforced rather than trusted, and a manifest the store has already moved
    /// past is refused with `sourceChanged` inside the same transaction.
    public func applyCorrection(to manifest: Manifest, sourceID: UUID, field: MetadataFieldID,
                                correctedValue: String?, evidenceIDs: [String],
                                origin: CorrectionRecord.Origin, scope: SourceScope,
                                profile: MappingProfile) async throws -> CorrectionEngine.Applied {
        let listing = try listing(scope)
        // Decided against the context the manifest cites. Rebuilding here would
        // bump a context revision as a side effect of a human edit, and would
        // judge the entry against candidates this manifest never had.
        guard let context = try await storedContext(scope: scope, profile: profile,
                                                    revision: manifest.envelope.contextRevision) else {
            throw FormaError.unavailable
        }
        // Revalidation resolves citations for every entry, so the rows are read
        // in one query rather than one round trip per file.
        let evidence = try await store.database.read { db in
            try MappingStore.evidence(for: Set(manifest.entries.map(\.sourceID)), in: db)
        }
        let applied = CorrectionEngine(profile: profile).apply(
            to: manifest, sourceID: sourceID, field: field, correctedValue: correctedValue,
            evidenceIDs: evidenceIDs, origin: origin, context: context, evidence: evidence,
            currentEntries: listing.entries)
        if applied.violations.isEmpty {
            // Version and decision are one unit of work: a failure between the
            // two writes would leave a row claiming a revision that was never
            // stored, and the unique index would then refuse the retry.
            let published = try await store.database.write { db -> (manifest: Manifest,
                                                                    record: CorrectionRecord) in
                // The revision under review must still be current, or a
                // decision made against revision 3 would be published over
                // revision 4 and silently discard it; `persist` numbers from the
                // store, so this is the only place that can tell the two apart.
                guard try MappingStore.nextManifestRevision(manifestID: manifest.envelope.manifestID, in: db)
                        == manifest.envelope.revision + 1 else { throw FormaError.sourceChanged }
                // A collision after that check cannot be a user mistake: the
                // number is assigned here. It means the store already holds a
                // decision claiming it, which `.storage` reports - the error
                // vocabulary is a published contract, so no new case for it.
                let stored = try Self.persist(applied.manifest, scopeID: scope.id, in: db)
                var record = applied.correction
                record.producedRevision = stored.envelope.revision
                try MappingStore.insertCorrection(record, in: db)
                return (stored, record)
            }
            return CorrectionEngine.Applied(manifest: published.manifest, correction: published.record,
                                            violations: [])
        }
        // A refusal names the revision it aimed at and produces nothing: many
        // attempts may share a target, no two may claim one version.
        try await store.database.write { db in
            try MappingStore.insertCorrection(applied.correction, in: db)
        }
        return applied
    }

    /// Every correction attempt against one manifest, verified or refused.
    public func corrections(manifestID: UUID) async throws -> [CorrectionRecord] {
        try await store.database.read { db in
            try MappingStore.corrections(manifestID: manifestID, in: db)
        }
    }
}
