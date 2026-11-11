import Combine
import FormaCore
import Foundation

/// The single place FormaApp talks to FormaCore.
///
/// Views hold selections and present values; this model holds the workspace and
/// engine handles, starts and cancels the long tasks, and stores or reads state
/// through `SourceWorkspace`. Nothing here decides a value, a state or an
/// eligibility: the context builder, the evidence registry, the mapping engine,
/// the validator and the exporter do that, and their results are shown as they
/// come back. A value FormaCore did not produce is never invented: an absent
/// key, an unconsented request, a missing bundle or an unread file is reported
/// with FormaCore's own reason.
@MainActor
final class WorkspaceModel: ObservableObject {

    // MARK: - Work phases

    enum Phase: Equatable {
        case idle
        case scanning
        case buildingContext
        case capturingEvidence(done: Int, total: Int)
        case mapping
        case exporting
        case revalidating
        case reconciling
        case loadingManifest
        case correcting
        case discoveringMCP
        case previewing

        var isBusy: Bool { self != .idle }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .scanning: "Scanning…"
            case .buildingContext: "Building project context…"
            case .capturingEvidence(let done, let total): "Registering evidence \(done.formatted()) of \(total.formatted())…"
            case .mapping: "Mapping with the provider…"
            case .exporting: "Writing the export bundle…"
            case .revalidating: "Revalidating the bundle…"
            case .reconciling: "Reconciling stored revisions…"
            case .loadingManifest: "Reading the stored manifest…"
            case .correcting: "Recording the correction…"
            case .discoveringMCP: "Discovering the MCP server…"
            case .previewing: "Building the request preview…"
            }
        }
    }

    // MARK: - Rows the areas display

    struct MappingRow: Identifiable {
        let sourceID: UUID
        let entry: ManifestEntry
        let source: SourceEntry?
        let failure: FormaError?
        let candidates: [ContextCandidate]
        var id: UUID { sourceID }

        /// FormaCore's own field value for a slot, or the honest absence.
        func value(_ field: MetadataFieldID) -> String {
            entry.metadata[field] ?? "No value"
        }
    }

    struct ExceptionRow: Identifiable {
        let sourceID: UUID
        let relativePath: String
        let state: DecisionState
        let reason: String
        let codes: [String]
        let violations: [ValidationViolation]
        var id: UUID { sourceID }

        var codeList: String { codes.isEmpty ? "No violation code" : codes.joined(separator: " · ") }
    }

    struct RedactionTerm: Identifiable, Equatable {
        let id: UUID
        var term: String
        var role: RedactionPlan.Role

        init(id: UUID = UUID(), term: String, role: RedactionPlan.Role) {
            self.id = id
            self.term = term
            self.role = role
        }
    }

    // MARK: - Persisted keys
    //
    // `UserDefaults.standard` is the same store `@AppStorage` reads, so a value
    // written here is what a view's `@AppStorage` shows after a restart.
    private enum Keys {
        static let scope = "selectedSourceScope"
        static let profile = "selectedMappingProfile"
        static let provider = "mappingProvider"
        static let model = "mappingModel"
        static let entryLimit = "mappingEntryLimit"
        static let salt = "mappingRedactionSalt"
        static let terms = "mappingRedactionTerms"
    }

    /// Salt FormaCore itself uses for its identity plan, kept as the default so
    /// a term list added here behaves the same way as `RedactionPlan.none`.
    static let defaultSalt = "forma-default-salt"

    // MARK: - Published state

    @Published private(set) var scopes: [SourceScope] = []
    @Published private(set) var listing: SourceListing?
    @Published private(set) var profiles: [MappingProfile] = []
    @Published private(set) var context: ProjectContext?
    @Published private(set) var contextIsStale = false
    @Published private(set) var manifest: Manifest?
    @Published private(set) var rows: [MappingRow] = []
    @Published private(set) var exceptions: [ExceptionRow] = []
    @Published private(set) var outcome: MappingRunOutcome?
    @Published private(set) var reconciliation: ManifestReconciler.Decision?
    @Published private(set) var evidenceBySource: [UUID: [EvidenceRecord]] = [:]
    @Published private(set) var evidenceFailures: [UUID: FormaError] = [:]
    @Published private(set) var fileEvidence: SourceEvidence?
    @Published private(set) var exportSummary: ManifestExport.Summary?
    @Published private(set) var revalidation: ManifestExport.Revalidation?
    @Published private(set) var bundleURL: URL?
    @Published private(set) var casePack: CasePack?
    @Published private(set) var capabilities: DEVONthinkCapabilities?
    /// A request the engine planned for this listing: the bytes it would send
    /// and the shape of the batch those bytes came from.
    ///
    /// One value rather than a payload plus two counters, because the counters
    /// describe the batch the payload was built from. Kept apart, clearing the
    /// preview could leave two numbers on screen describing a request that no
    /// longer exists - and a count of files rendered as a fraction of batches
    /// says nothing in either unit.
    struct Preview {
        let value: ProviderMappingClient.Preview
        let fileCount: Int
        let batchCount: Int
    }
    @Published private(set) var preview: Preview?
    @Published private(set) var leakedTerms: [String] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String?
    @Published var error: FormaError?

    @Published var selectedScopeID: UUID? {
        didSet {
            guard oldValue != selectedScopeID else { return }
            // The model is the only writer of this key. A view that mirrored it
            // into @AppStorage on appear would race the fallback in `restore()`
            // and persist a scope id that no longer exists, so every start had
            // to repair it again - and switching scope then restarting could
            // land on a different source than the one chosen.
            defaults.set(selectedScopeID?.uuidString, forKey: Keys.scope)
            listing = nil
            context = nil
            contextIsStale = false
            manifest = nil
            outcome = nil
            // A reconciliation belongs to the manifest it was computed against.
            // Leaving it set showed the previous source's judgement next to an
            // empty listing for the new one.
            reconciliation = nil
            correctionHistory = []
            correctionHistoryState = .notRead
            draft = nil
            clearFileEvidence()
            refreshRows()
            scheduleReload()
        }
    }

    @Published var selectedProfileID: String? {
        didSet {
            guard oldValue != selectedProfileID else { return }
            // Persisting and invalidating the engine are separate duties, and
            // neither may be skipped because a value arrived during restore:
            // `restore()` falls back to the first profile when the stored one is
            // gone, and that fallback is the answer the next start should read,
            // not another repair to perform.
            defaults.set(selectedProfileID, forKey: Keys.profile)
            engineCache = nil
            scheduleReload()
        }
    }
    /// Starts a reload for a value the reviewer changed, unless `restore()` is
    /// still assembling launch state. Two reloads running together each write
    /// the listing, context, manifest and attempts after their own suspensions,
    /// so which set survives would depend on which read returned last.
    private func scheduleReload() {
        guard !isRestoring else { return }
        Task { await self.reload() }
    }

    @Published var provider: ProbeProvider {
        didSet {
            guard oldValue != provider else { return }
            defaults.set(provider.rawValue, forKey: Keys.provider)
        }
    }

    @Published var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.model) }
    }

    @Published var entryLimit: Int {
        didSet { defaults.set(entryLimit, forKey: Keys.entryLimit) }
    }

    /// Cloud egress consent, never persisted: off at every launch, and
    /// FormaCore's client refuses the request without it.
    @Published var allowCloud = false

    @Published var redactionSalt: String {
        didSet { defaults.set(redactionSalt, forKey: Keys.salt) }
    }

    @Published var redactionTerms: [RedactionTerm] {
        didSet { Self.store.save(terms: redactionTerms, forKey: Keys.terms) }
    }

    // MARK: - Handles

    private let workspace: SourceWorkspace
    private let defaults = UserDefaults.standard
    /// The engine together with the identity it was built for. One value, so a
    /// cache and its validity key cannot be out of step with each other.
    private var engineCache: (key: String, engine: MappingEngine)?
    private var work: Task<Void, Never>?
    private var fileWork: Task<Void, Never>?
    /// Which read still owns `fileWork`. A cancelled task outlives its handle,
    /// so ownership is a number the retiring side advances rather than the
    /// handle itself.
    private var fileRead = 0
    /// Whether a file read is in flight; `cancelFileRead()` is the only task it
    /// can stop, and `phase` describes the long task instead.
    @Published private(set) var fileReadInFlight = false
    /// Set only while `restore()` assembles launch state, and read only by
    /// `scheduleReload()`.
    private var isRestoring = false
    private var auxWork: Task<Void, Never>?

    private static let store = UserDefaults.standard

    init(workspace: SourceWorkspace) {
        self.workspace = workspace
        // Reads go through the shared defaults instance rather than the
        // `defaults` property: Swift forbids touching `self` - and a property
        // read is a `self` use - until every stored property has a value, and
        // the assignments below are exactly what gives them one.
        let storedProvider = ProbeProvider.allCases.first { $0.rawValue == Self.store.string(forKey: Keys.provider) }
            ?? .openAI
        provider = storedProvider
        modelID = Self.store.string(forKey: Keys.model) ?? storedProvider.defaultModel
        entryLimit = (Self.store.object(forKey: Keys.entryLimit) as? Int) ?? MappingPrompt.defaultEntryLimit
        redactionSalt = Self.store.string(forKey: Keys.salt) ?? Self.defaultSalt
        redactionTerms = Self.store.loadTerms(forKey: Keys.terms)
        selectedProfileID = Self.store.string(forKey: Keys.profile)
        selectedScopeID = UUID(uuidString: Self.store.string(forKey: Keys.scope) ?? "")
    }

    // MARK: - Derived values

    var selectedScope: SourceScope? { scopes.first { $0.id == selectedScopeID } }

    var selectedProfile: MappingProfile? { profiles.first { $0.profileID == selectedProfileID } }

    var canMap: Bool { selectedScope != nil && selectedProfile != nil && context != nil && !phase.isBusy }

    /// The plan FormaCore applies to a request. An empty term list is FormaCore's
    /// identity plan, so nothing is substituted.
    var redaction: RedactionPlan {
        guard !redactionTerms.isEmpty else { return .none }
        var terms: [String: RedactionPlan.Role] = [:]
        for entry in redactionTerms where !entry.term.isEmpty {
            terms[entry.term] = entry.role
        }
        guard !terms.isEmpty else { return .none }
        return RedactionPlan(terms: terms, salt: redactionSalt)
    }

    var roleInventory: [RedactionPlan.Role: Int] { redaction.roles }

    /// Evidence rows this session has read, keyed by citation id: the review
    /// screen resolves one per field chip per render. `merge` writes it in the
    /// same walk that rebuilds `evidenceBySource`, for the sources that batch
    /// touched, so the two views of the same rows cannot drift apart.
    @Published private(set) var recordsByID: [String: EvidenceRecord] = [:]

    func record(for id: String) -> EvidenceRecord? { recordsByID[id] }

    func clusterKeys(for sourceID: UUID) -> [String] {
        context?.candidate(for: sourceID).map(\.projectKey) ?? []
    }

    func clusterLabel(for sourceID: UUID) -> String {
        guard let context else { return "No context" }
        var labels = context.candidate(for: sourceID).map(\.projectKey)
        if context.conflictedSourceIDs.contains(sourceID) { labels.append("Conflicted") }
        if labels.isEmpty { return "Unassigned" }
        return labels.sorted().joined(separator: " · ")
    }

    func entry(with sourceID: UUID) -> SourceEntry? { listing?.entries.first { $0.id == sourceID } }

    func files(in candidateID: String) -> [SourceEntry] {
        guard let candidate = context?.candidates.first(where: { $0.id == candidateID }),
              let listing else { return [] }
        return listing.entries
            .filter { candidate.memberSourceIDs.contains($0.id) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    func files(in set: Set<UUID>) -> [SourceEntry] {
        (listing?.entries ?? []).filter { set.contains($0.id) }.sorted { $0.relativePath < $1.relativePath }
    }

    /// One row of the cluster panel: a FormaCore candidate, plus the two
    /// categories FormaCore keeps separate so no file disappears from view.
    struct ClusterRow: Identifiable {
        enum Kind {
            case candidate, unassigned, conflicted
        }

        let id: String
        let kind: Kind
        let title: String
        let fileCount: Int
        let basis: String
        let confidence: String
    }

    static let unassignedRowID = "forma:unassigned"
    static let conflictedRowID = "forma:conflicted"

    var clusterRows: [ClusterRow] {
        guard let context else { return [] }
        var rows = context.candidates.map { candidate in
            ClusterRow(id: candidate.id, kind: .candidate,
                       title: candidate.displayName ?? candidate.projectKey,
                       fileCount: candidate.memberSourceIDs.count,
                       basis: candidate.basis.map(\.rawValue).joined(separator: " · "),
                       confidence: candidate.confidence.rawValue)
        }
        rows.append(ClusterRow(id: Self.unassignedRowID, kind: .unassigned,
                               title: "Unassigned · \(context.unassignedSourceIDs.count.formatted())",
                               fileCount: context.unassignedSourceIDs.count,
                               basis: "No candidate FormaCore could defend", confidence: "—"))
        rows.append(ClusterRow(id: Self.conflictedRowID, kind: .conflicted,
                               title: "Conflicted · \(context.conflictedSourceIDs.count.formatted())",
                               fileCount: context.conflictedSourceIDs.count,
                               basis: "Members disagree about the project", confidence: "—"))
        return rows
    }

    func files(in row: ClusterRow) -> [SourceEntry] {
        switch row.kind {
        case .candidate: return files(in: row.id)
        case .unassigned: return files(in: context?.unassignedSourceIDs ?? [])
        case .conflicted: return files(in: context?.conflictedSourceIDs ?? [])
        }
    }

    // MARK: - Restore and loads

    func restore() async {
        // Assigning the launch state would otherwise schedule one reload per
        // identifier; this is the only caller that suppresses them, and it
        // reloads once, at the end.
        isRestoring = true
        defer { isRestoring = false }
        do {
            profiles = try MappingProfile.shipped()
        } catch {
            show(error, operation: .providerProbe, fallback: .unavailable)
        }
        if selectedProfile == nil { selectedProfileID = profiles.first?.profileID }
        do {
            casePack = try CasePack.shipped()
        } catch {
            show(error, operation: .providerProbe, fallback: .unavailable)
        }
        do {
            scopes = try await workspace.scopes()
            if scopes.contains(where: { $0.id == selectedScopeID }) == false {
                // The stored identifier names a source that is gone. Falling
                // back is the answer the next launch should read, so the
                // assignment still persists it; only the reload is deferred to
                // the single one below.
                selectedScopeID = scopes.first?.id
            }
        } catch {
            show(error, operation: .openWorkspace, fallback: .storage)
        }
        await reload()
    }

    /// Reloads the listing plus whatever FormaCore has stored for this
    /// scope/profile pair: the current context revision, the latest manifest and
    /// the reconciliation verdict after a rescan.
    func reload() async {
        guard let scope = selectedScope else {
            listing = nil
            context = nil
            manifest = nil
            refreshRows()
            return
        }
        do {
            let result = try await workspace.listing(scope)
            guard scope.id == selectedScopeID else { return }
            listing = result
        } catch {
            if !Task.isCancelled { show(error, operation: .openWorkspace, fallback: .storage) }
            return
        }
        guard let profile = selectedProfile else { return }
        do {
            // Dropped before the work rather than only when it succeeds: the
            // early returns below - no profile, a context the store cannot
            // resolve - would otherwise leave an empty list reading like
            // "nobody attempted anything".
            correctionHistoryState = .notRead
            let digest = ContextBuilder.inputDigest(scopeID: scope.id, profile: profile, entries: listing?.entries ?? [])
            let stored = try await workspace.storedContext(scope: scope, profile: profile, inputDigest: digest)
            guard scope.id == selectedScopeID, profile.profileID == selectedProfileID else { return }
            context = stored
            contextIsStale = false
            let current = try await workspace.currentManifest(scope: scope, profile: profile)
            guard scope.id == selectedScopeID, profile.profileID == selectedProfileID else { return }
            if let current {
                manifest = current
                outcome = nil
                // Correction attempts live in the store, not in this session:
                // without reading them back, a restart or a scope switch shows
                // an empty list next to a manifest that does have a history, and
                // a refused decision becomes invisible exactly when someone
                // returns to look for it.
                let attempts = try await workspace.corrections(manifestID: current.envelope.manifestID)
                // The attempts are read after the manifest, and a scope switch
                // in between would otherwise attach another source's audit
                // history to this one.
                guard scope.id == selectedScopeID, profile.profileID == selectedProfileID else { return }
                correctionHistory = attempts
                correctionHistoryState = .fromStore
            } else {
                correctionHistory = []
                correctionHistoryState = .notRead
            }
            refreshRows()
        } catch {
            if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
        }
    }

    /// Recomputes staleness from FormaCore's own input digest.
    func refreshStaleness() {
        guard let context, let scope = selectedScope, let profile = selectedProfile, let listing else {
            contextIsStale = false
            return
        }
        contextIsStale = context.inputDigest
            != ContextBuilder.inputDigest(scopeID: scope.id, profile: profile, entries: listing.entries)
    }

    // MARK: - Source actions

    func register(_ url: URL) async {
        do {
            let scope = try await workspace.register(url)
            scopes = try await workspace.scopes()
            selectedScopeID = scope.id
        } catch {
            show(error, operation: .registerSource, fallback: .invalidSource)
        }
    }

    func scan() {
        guard phase == .idle, let scope = selectedScope else { return }
        fileEvidence = nil
        phase = .scanning
        notice = nil
        work = Task {
            defer { finishWork() }
            do {
                let updated = try await workspace.scan(scope)
                guard !Task.isCancelled, scope.id == self.selectedScopeID else { return }
                listing = updated
                refreshStaleness()
                notice = updated.isComplete
                    ? "Scan complete · \(updated.entries.count.formatted()) files · build a context before mapping."
                    : "Scan finished incomplete · FormaCore reported \(updated.issues.count.formatted()) issues."
            } catch {
                if let saved = try? await workspace.listing(scope), scope.id == self.selectedScopeID {
                    listing = saved
                    refreshStaleness()
                }
                if !Task.isCancelled { show(error, operation: .scanSource, fallback: .invalidSource) }
            }
        }
    }

    /// Asks FormaCore which stored entries its snapshot binding no longer
    /// supports. FormaCore writes the invalidation; this only reports it.
    func reconcile() {
        guard phase == .idle, let scope = selectedScope, let profile = selectedProfile else { return }
        phase = .reconciling
        work = Task {
            defer { finishWork() }
            do {
                // Both reads finish before either result is published: this is
                // the same rule the other long tasks follow, and writing the
                // verdict first meant a scope switch could leave one source's
                // judgement attached to another source's manifest.
                let decision = try await workspace.reconcile(scope: scope, profile: profile)
                let current = try await workspace.currentManifest(scope: scope, profile: profile)
                guard !Task.isCancelled, scope.id == selectedScopeID,
                      profile.profileID == selectedProfileID else { return }
                reconciliation = decision
                if let current {
                    manifest = current
                    refreshRows()
                }
                guard let decision else {
                    notice = "No stored manifest for this profile, so nothing to reconcile."
                    return
                }
                notice = decision.invalidatedSourceIDs.isEmpty
                    ? "Nothing invalidated · \(decision.reason)"
                    : "\(decision.invalidatedSourceIDs.count.formatted()) entries invalidated · \(decision.reason) · the rest stay usable"
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
        }
    }

    func buildContext() {
        guard phase == .idle, let scope = selectedScope, let profile = selectedProfile else {
            error = .unavailable
            notice = "Choose a source and a profile first."
            return
        }
        phase = .buildingContext
        work = Task {
            defer { finishWork() }
            do {
                let built = try await workspace.buildContext(scope: scope, profile: profile)
                guard !Task.isCancelled, scope.id == self.selectedScopeID,
                      profile.profileID == self.selectedProfileID else { return }
                context = built
                contextIsStale = false
                notice = "Context revision \(built.revision.formatted()) · \(built.candidates.count.formatted()) candidates · "
                    + "\(built.unassignedSourceIDs.count.formatted()) unassigned · "
                    + "\(built.conflictedSourceIDs.count.formatted()) conflicted."
            } catch {
                if !Task.isCancelled { show(error, operation: .providerProbe, fallback: .unavailable) }
            }
        }
    }

    func readFileEvidence(_ entry: SourceEntry, extracting: Bool) {
        guard fileWork == nil else { return }
        fileEvidence = nil
        // The read owns its own in-flight flag rather than borrowing `phase`.
        // `phase` describes the long task that the toolbars' Cancel button
        // stops; a second occupant of the same value means a button that reads
        // "Cancel" while pointing at a task that is not running, and a busy
        // flag that blocks unrelated work for the length of a file open.
        fileReadInFlight = true
        fileRead += 1
        let generation = fileRead
        fileWork = Task {
            defer {
                // Only the read that is still current may release the slot.
                // clearFileEvidence() cancels cooperatively and drops the
                // handle itself, so a task that is still unwinding must not
                // nil out the handle of the newer read that started after it -
                // that would leave a running task nothing can cancel or report.
                if generation == fileRead {
                    fileWork = nil
                    fileReadInFlight = false
                }
            }
            do {
                let result = extracting
                    ? try await workspace.evidence(for: entry)
                    : try await workspace.hash(for: entry)
                guard !Task.isCancelled, generation == fileRead else { return }
                fileEvidence = result
                if let rows = try? await workspace.evidenceRegistry(for: entry.id),
                   generation == fileRead {
                    merge(rows)
                }
            } catch {
                if !Task.isCancelled, generation == fileRead {
                    show(error, operation: .readEvidence, fallback: .unavailable)
                }
            }
        }
    }

    func cancelFileRead() {
        fileWork?.cancel()
    }

    /// Drops the file detail panel's evidence and stops its read. The registry
    /// keeps its rows: FormaCore owns them until a re-read replaces them.
    func clearFileEvidence() {
        // Nothing to retire when no read is in flight and no detail is shown.
        // The model clears this on a source switch and the view clears it when
        // the selection changes, and the two can fire for the same click; the
        // guard keeps the second one from bumping the generation for no reason.
        guard fileEvidence != nil || fileWork != nil || fileReadInFlight else { return }
        // Retire the generation before touching the handle, so the cancelled
        // task recognises its own cleanup as stale.
        fileRead += 1
        fileWork?.cancel()
        fileWork = nil
        fileReadInFlight = false
        fileEvidence = nil
    }

    /// Loads the registry rows one manifest entry cites so a field chip can show
    /// its excerpt and locator, including after a restart.
    ///
    /// Read every time rather than once per source: the rows a source has are
    /// replaced by FormaCore on each re-read and by every mapping run, so a
    /// "already loaded" marker would be a cache with no invalidation, and the
    /// chip would keep showing the excerpt the correction no longer cites.
    func loadEvidence(for sourceID: UUID) async {
        do {
            merge(try await workspace.evidenceRegistry(for: sourceID))
        } catch {
            if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
        }
    }

    /// Folds freshly read rows into the per-source view. Rows are unioned by
    /// id rather than replacing a source's list: a capture that returns only
    /// what it just extracted must not hide the rows an older revision cites,
    /// because those rows are what makes an old manifest verifiable.
    private func merge(_ records: [EvidenceRecord]) {
        guard !records.isEmpty else { return }
        // Updated in place, source by source: only the sources this batch
        // touched can have changed. A citation id hashes its source id
        // (`EvidenceRegistry.identifier`), so a row cannot live in two buckets;
        // within one, the batch's rows are applied last, which makes "the
        // newest read owns the id" a property of this loop rather than of
        // dictionary ordering.
        for sourceID in Set(records.map(\.sourceID)) {
            var byID: [String: EvidenceRecord] = [:]
            for record in evidenceBySource[sourceID] ?? [] where record.sourceID == sourceID {
                byID[record.id] = record
            }
            for record in records where record.sourceID == sourceID {
                byID[record.id] = record
            }
            let rows = byID.values.sorted { $0.id < $1.id }
            evidenceBySource[sourceID] = rows
            for row in rows { recordsByID[row.id] = row }
        }
    }

    // MARK: - Mapping run

    /// Runs `MappingEngine` over the current listing, or over one selection when
    /// reprocessing exceptions. Evidence is registered through FormaCore first,
    /// so every citation a provider answer can make already exists in the store.
    /// `egress` is this run's consent, passed to FormaCore as
    /// `MappingRunRequest.allowCloud`. The local assessment path passes `false`
    /// and FormaCore's own client reports the refusal per file.
    /// Returns whether a request was actually dispatched. Consent is one-shot,
    /// and a run that never left the guard list never used it: a caller that
    /// cleared its own checkbox on a `false` would make the user re-consent to
    /// the same bytes after a failure that involved no transmission at all.
    @discardableResult
    func runMapping(sourceIDs: Set<UUID>? = nil, egress: Bool) -> Bool {
        guard phase == .idle else { return false }
        guard let scope = selectedScope, let profile = selectedProfile, let listing else {
            error = .unavailable
            notice = "Choose a source before mapping."
            return false
        }
        guard let context else {
            error = .unavailable
            notice = "Build a project context first: FormaCore will not map files without one."
            return false
        }
        guard let casePack else {
            error = .unavailable
            notice = "The shipped CasePack could not be loaded, so no request can be built."
            return false
        }
        let targets: [SourceEntry]
        if let sourceIDs {
            targets = listing.entries.filter { sourceIDs.contains($0.id) }
            if targets.isEmpty {
                notice = "The selected files are no longer in this listing."
                return false
            }
        } else {
            targets = listing.entries
        }
        guard let engine = engine(for: profile) else { return false }

        let provider = self.provider
        let model = modelID
        let consent = egress
        let limit = entryLimit
        let plan = redaction
        allowCloud = false
        notice = nil
        exportSummary = nil
        revalidation = nil
        phase = .capturingEvidence(done: 0, total: targets.count)
        // The run identity records the versions that produced it, so a report
        // can say which profile, context, case pack and model answered. The
        // guard above already required a case pack to be loaded.
        let run = MappingRun(scopeID: scope.id, profile: profile, contextRevision: context.revision,
                             casePackVersion: casePack.version,
                             modelProvider: provider.rawValue, modelID: model,
                             promptVersion: MappingPrompt.version)
        work = Task {
            defer {
                finishWork()
            }
            var captured: [UUID: [EvidenceRecord]] = [:]
            var unread: [UUID: FormaError] = [:]
            for (index, entry) in targets.enumerated() {
                if Task.isCancelled { break }
                self.phase = .capturingEvidence(done: index, total: targets.count)
                do {
                    captured[entry.id] = try await self.workspace.captureEvidence(for: entry)
                } catch {
                    // FormaCore registers what it can read. A file it cannot
                    // read simply has no rows for a provider answer to cite, and
                    // the validator records that as its own reason.
                    unread[entry.id] = error as? FormaError ?? .unavailable
                }
            }
            self.evidenceFailures = unread
            if Task.isCancelled {
                // Written before the store call, not after: the run is over
                // when this line executes, and a suspension here would let the
                // notice describe a panel somebody else had already started
                // work in.
                notice = "Cancelled during evidence capture · no provider request was made."
                try? await self.workspace.finishMappingRun(id: run.id, state: .cancelled, batches: 0,
                                                           error: .cancelled)
                return
            }
            self.merge(captured.values.flatMap { $0 })
            do {
                try await self.workspace.startMappingRun(run)
            } catch {
                // Only the panel this run belongs to may be told it failed.
                guard scope.id == self.selectedScopeID, profile.profileID == self.selectedProfileID else { return }
                self.show(error, operation: .providerProbe, fallback: .storage)
            }
            self.phase = .mapping
            let result = await engine.run(MappingRunRequest(scope: scope, profile: profile, context: context,
                                                             entries: targets, evidence: captured,
                                                             provider: provider, model: model,
                                                             allowCloud: consent, redaction: plan,
                                                             entryLimit: limit))
            if Task.isCancelled {
                // A cancellation that arrives after `engine.run` has returned
                // has already spent the provider requests it made, and the
                // answers are still thrown away. That is the cheaper of two
                // wrong options: storing them would publish a revision built
                // from part of the listing and replace the complete one that
                // is currently usable. The notice says so rather than letting
                // "Cancelled" imply nothing was learned. It is written before
                // the store call so no other action can claim the channel in
                // between.
                notice = "Run cancelled after \(result.batches.formatted()) batches. Answers that had already "
                    + "returned are recorded in the run history but not published: a revision is written only by "
                    + "a run that finished, and this one's would have replaced the complete revision with a partial one."
                try? await self.workspace.finishMappingRun(id: run.id, state: .cancelled,
                                                            batches: result.batches, error: .cancelled)
                return
            }
            var stored = result.manifest
            do {
                stored = try await self.workspace.saveManifest(result.manifest, scopeID: scope.id)
            } catch {
                if scope.id == self.selectedScopeID, profile.profileID == self.selectedProfileID {
                    self.show(error, operation: .providerProbe, fallback: .invalidOutput)
                    notice = "FormaCore kept this result in memory only: the revision was not stored."
                }
            }
            // FormaCore's own vocabulary: a run that returned completed. The
            // per-file provider failures stay in the outcome, where they are
            // reported file by file rather than as one invented error code.
            try? await self.workspace.finishMappingRun(id: run.id, state: .completed,
                                                       batches: result.batches, error: nil)
            guard scope.id == self.selectedScopeID, profile.profileID == self.selectedProfileID else { return }
            self.manifest = stored
            self.outcome = result
            self.reconciliation = nil
            self.notice = "Run \(run.id.uuidString.lowercased()) · \(result.batches.formatted()) batches · "
                + "\(result.requests.formatted()) provider requests · "
                + "\(result.failures.count.formatted()) file failures · "
                + "\(result.refusedReferences.formatted()) refused references · "
                + "\(unread.count.formatted()) files FormaCore could not read."
            self.refreshRows()
        }
        return true
    }

    func cancelWork() {
        work?.cancel()
    }

    func cancelAux() {
        auxWork?.cancel()
    }

    func cancelAll() {
        work?.cancel()
        fileWork?.cancel()
        auxWork?.cancel()
    }

    // MARK: - Export, load and revalidate

    func export(to directory: URL) {
        guard phase == .idle, let manifest else {
            if manifest == nil { notice = "There is no manifest to export yet." }
            return
        }
        let plan = redactionTerms.isEmpty ? nil : redaction
        let records = evidenceBySource.values.flatMap { $0 }
        phase = .exporting
        work = Task {
            defer { finishWork() }
            do {
                let summary = try ManifestExport.export(manifest: manifest, evidence: records, to: directory,
                                                       redaction: plan)
                guard !Task.isCancelled else { return }
                exportSummary = summary
                bundleURL = directory.appendingPathComponent(summary.manifestID, isDirectory: true)
                notice = "Exported \(summary.files.count.formatted()) files for revision \(summary.revision.formatted())."
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .storage) }
            }
        }
    }

    /// Reads a written bundle: the manifest for offline viewing and its evidence
    /// rows so field chips resolve without a provider or a rescan.
    func loadBundle(from url: URL) {
        guard phase == .idle else { return }
        let boundScope = selectedScopeID
        let boundProfile = selectedProfileID
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let bundle = isDirectory ? url : url.deletingLastPathComponent()
        let manifestURL = isDirectory ? bundle.appendingPathComponent(ManifestExport.manifestFile) : url
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            error = .unavailable
            notice = "\(bundle.path) has no \(ManifestExport.manifestFile), so it is not a Forma export bundle."
            return
        }
        phase = .loadingManifest
        work = Task {
            defer { finishWork() }
            do {
                let loaded = try FormaJSON.decode(Manifest.self, from: Data(contentsOf: manifestURL))
                var loadedRecords: [EvidenceRecord] = []
                let evidenceURL = bundle.appendingPathComponent(ManifestExport.evidenceFile)
                if FileManager.default.fileExists(atPath: evidenceURL.path) {
                    loadedRecords = try FormaJSON.decode([EvidenceRecord].self, from: Data(contentsOf: evidenceURL))
                }
                // The bundle's entries are combined with the current listing
                // when rows are rebuilt, so this is only meaningful while the
                // source selected at the click is still selected: a switch
                // during the read would pair a foreign manifest with another
                // source's rows and present the mixture as one table.
                guard !Task.isCancelled, selectedScopeID == boundScope,
                      selectedProfileID == boundProfile else { return }
                self.merge(loadedRecords)
                self.manifest = loaded
                self.outcome = nil
                // A loaded bundle carries no local attempt history: those rows
                // live in the store of whoever exported it, and showing this
                // session's stale list beside a foreign manifest would
                // attribute decisions to the wrong reviewer.
                self.correctionHistory = []
                self.correctionHistoryState = .offlineBundle
                self.bundleURL = bundle
                self.revalidation = nil
                self.notice = "Loaded revision \(loaded.envelope.revision.formatted()) from \(bundle.path) · "
                    + "\(loaded.entries.count.formatted()) entries · \(loadedRecords.count.formatted()) evidence rows offline."
                self.refreshRows()
            } catch {
                if !Task.isCancelled {
                    FormaDiagnostics.failure(.readEvidence, .unavailable)
                    self.error = .unavailable
                    self.notice = "\(manifestURL.lastPathComponent) is not a Forma manifest FormaCore can decode."
                }
            }
        }
    }
    /// Reports why the file picker returned no bundle. The wording is the
    /// system's own failure text, so the reason shown is not invented here.
    func importRejected(_ failure: any Error) {
        FormaDiagnostics.failure(.readEvidence, .unavailable)
        error = .unavailable
        notice = failure.localizedDescription
    }

    func revalidate() {
        guard phase == .idle else { return }
        guard let bundleURL else {
            error = .unavailable
            notice = "No bundle is selected: export a manifest or open a bundle first."
            return
        }
        phase = .revalidating
        work = Task {
            defer { finishWork() }
            do {
                let result = try ManifestExport.revalidate(at: bundleURL)
                // The conclusion describes the bundle the click named. If a
                // different bundle was opened while this one was being checked,
                // hanging this verdict on it would report a file nobody asked
                // about.
                guard !Task.isCancelled, self.bundleURL == bundleURL else { return }
                revalidation = result
                notice = result.artifactConsistent
                    ? "Bundle is self-consistent · revision \(result.revision.formatted())."
                    : "Bundle has \(result.violations.count.formatted()) violations · revision \(result.revision.formatted())."
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
        }
    }

    // MARK: - Correction capture

    /// A reviewer's in-flight decision. The draft is the only place the app
    /// holds an unverified value: FormaCore decides whether it becomes a
    /// revision, and nothing here pre-judges that.
    struct CorrectionDraft: Equatable, Identifiable {
        let sourceID: UUID
        let field: MetadataFieldID
        var value: String
        var citations: Set<String>
        /// One sheet per file and slot: two fields of the same file are two
        /// different decisions, and a draft that only keyed the file would let
        /// one sheet edit the other's value.
        var id: String { "\(sourceID.uuidString)|\(field.rawValue)" }
    }

    @Published var draft: CorrectionDraft?
    @Published private(set) var correctionHistory: [CorrectionRecord] = []
    /// What `correctionHistory` currently describes.
    ///
    /// An empty list means three different things depending on how it got
    /// empty, and a boolean could name two of them: not read yet, read from
    /// this store, or belonging to a bundle whose history is on another machine.
    enum CorrectionHistoryState {
        /// Nothing has been read for the manifest now on screen.
        case notRead
        /// The rows below are everything the local store holds for it, and an
        /// empty list is then a fact about the manifest.
        case fromStore
        /// The manifest came from an exported bundle: its attempts live in the
        /// store of whoever exported it and cannot be read from here at all.
        case offlineBundle
    }
    @Published private(set) var correctionHistoryState: CorrectionHistoryState = .notRead

    /// Opens the sheet for one field, seeded with FormaCore's own value so the
    /// reviewer sees what they are overwriting rather than an empty box.
    func beginCorrection(sourceID: UUID, field: MetadataFieldID) {
        guard let row = rows.first(where: { $0.sourceID == sourceID }) else { return }
        let current = row.entry.metadata[field] ?? ""
        draft = CorrectionDraft(sourceID: sourceID, field: field, value: current,
                                citations: Set(row.entry.fields.first { $0.field == field }?.evidenceIDs ?? []))
        // The sheet offers the registered rows to cite, and after a restart the
        // in-memory dictionary is empty even though the registry is not. Without
        // this read a returning reviewer would see no candidates, could cite
        // nothing, and every correction would be refused as an opinion.
        Task { await loadEvidence(for: sourceID) }
    }

    func cancelCorrection() { draft = nil }

    /// Records a human decision. The engine, not this screen, decides whether
    /// it is supported: a click that cites nothing is stored as a refused
    /// attempt and changes no revision, and the notice has to say that instead
    /// of showing a checkmark for something that did not happen.
    func applyCorrection() {
        guard phase == .idle, let manifest, let scope = selectedScope, let profile = selectedProfile,
              let draft else { return }
        // What is being corrected is identified against what is selected: the
        // sheet can outlive a source switch, and a decision about one project
        // must not be shown as a result on another.
        guard manifest.envelope.scopeID == scope.id,
              manifest.envelope.profileID == profile.profileID,
              manifest.envelope.profileVersion == profile.profileVersion else {
            self.draft = nil
            notice = "That correction was opened against a different source or profile. Close the sheet and open it again."
            return
        }
        let trimmed = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let citations = draft.citations.sorted()
        let manifestID = manifest.envelope.manifestID
        phase = .correcting
        work = Task {
            defer { finishWork() }
            do {
                let applied = try await workspace.applyCorrection(
                    to: manifest, sourceID: draft.sourceID, field: draft.field,
                    correctedValue: trimmed.isEmpty ? nil : trimmed, evidenceIDs: citations,
                    origin: .manual, scope: scope, profile: profile)
                guard !Task.isCancelled else { return }
                // A source switch while the click was in flight must not write
                // the decision onto the screen the reviewer left; the check
                // follows each suspension, not only the first.
                guard scope.id == selectedScopeID, profile.profileID == selectedProfileID else { return }
                // The decision is in storage from here on, so nothing below can
                // undo it: the two reads only refine the screen, and an error
                // in either used to conceal a correction that had succeeded.
                var message = applied.violations.isEmpty
                    ? "Correction recorded as revision \(applied.manifest.envelope.revision.formatted())."
                    : "FormaCore refused this correction: \(applied.violations.map { $0.code }.joined(separator: " · ")). "
                        + "Nothing was changed, and the attempt is on the exceptions list."
                // Both reads finish before any state is written. Publishing in
                // steps let a scope change during a read land another source's
                // manifest here with this source's listing under it. The reads
                // are explicit `do`/`catch` rather than `try?` because these
                // calls already answer optionally: `try?` over them nests the
                // optional, and a failure and a nil would look alike below.
                var stored: Manifest?
                do { stored = try await workspace.currentManifest(scope: scope, profile: profile) }
                catch { stored = nil }
                var attempts: [CorrectionRecord]?
                do { attempts = try await workspace.corrections(manifestID: manifestID) }
                catch { attempts = nil }
                guard !Task.isCancelled, scope.id == selectedScopeID,
                      profile.profileID == selectedProfileID else { return }
                var shown = applied.manifest
                if let stored = stored, stored.envelope.revision != applied.manifest.envelope.revision {
                    // The manifest moved on between the write and this read:
                    // the notice names both numbers instead of letting the
                    // header show one and the audit trail another.
                    message = "Correction recorded as revision "
                        + "\(applied.manifest.envelope.revision.formatted()); the manifest has since advanced to revision "
                        + "\(stored.envelope.revision.formatted())."
                    shown = stored
                }
                self.manifest = shown
                self.draft = nil
                refreshRows()
                if let history = attempts {
                    correctionHistory = history
                    correctionHistoryState = .fromStore
                } else {
                    correctionHistory = [applied.correction]
                    correctionHistoryState = .notRead
                }
                notice = message
            } catch {
                if !Task.isCancelled { show(error, operation: .applyCorrection, fallback: .storage) }
            }
        }
    }

    // MARK: - Settings actions

    func selectProvider(_ provider: ProbeProvider) {
        guard provider != self.provider else { return }
        if modelID == self.provider.defaultModel { modelID = provider.defaultModel }
        self.provider = provider
        allowCloud = false
        preview = nil
        leakedTerms = []
    }

    /// Saves the key through FormaCore's own Keychain store and reports whether
    /// it was stored. An invalid key is FormaCore's `credentialMissing`.
    @discardableResult func saveKey(_ key: String) -> Bool {
        let client = ProviderMappingClient()
        do {
            try client.saveKey(key, for: provider)
            notice = "API key saved in Keychain for \(provider.displayName)."
            return true
        } catch {
            let safe = error as? FormaError ?? .storage
            FormaDiagnostics.failure(.saveCredential, safe)
            self.error = safe
            notice = nil
            return false
        }
    }

    /// Describes the request a run would build from the stored evidence,
    /// without sending anything.
    ///
    /// "Describes" rather than "the exact bytes": a run re-reads file bodies
    /// before dispatch, so the excerpt shown here is what the registered rows
    /// produce, not a receipt for what a run will attach.
    ///
    /// The inputs the request is built from - source, profile, context
    /// revision, batch limit, redaction terms and salt - are read off the
    /// panel at the click and compared with the panel again before anything is
    /// published, so a preview cannot describe one request while the fields
    /// beside it describe another.
    func previewEgress() {
        guard auxWork == nil else { return }
        guard let scope = selectedScope, let profile = selectedProfile, let context, let casePack,
              let listing else {
            error = .unavailable
            notice = "A preview needs a source, a profile and a stored project context."
            return
        }
        let limit = entryLimit
        let terms = redactionTerms
        let salt = redactionSalt
        let plan = redaction
        let contextRevision = context.revision
        let casePackVersion = casePack.version
        preview = nil
        auxWork = Task {
            defer { auxWork = nil; if phase == .previewing { phase = .idle } }
            self.phase = .previewing
            do {
                let rows = try await workspace.registeredEvidence(for: Set(listing.entries.map(\.id)))
                let batches = MappingEngine.plannedBatches(from: listing.entries, context: context,
                                                          limit: limit, evidence: rows)
                // The read suspends while every one of these can move: the
                // toolbar switches source or profile, `reload` restores a
                // different stored context, `restore` can still be assigning the
                // case pack from launch, and the Settings fields - limit, terms,
                // salt - are editable throughout (only the provider picker is
                // disabled while a preview runs).
                guard !Task.isCancelled, scope.id == selectedScopeID,
                      profile.profileID == selectedProfileID,
                      contextRevision == self.context?.revision,
                      casePackVersion == self.casePack?.version, limit == entryLimit,
                      terms == redactionTerms, salt == redactionSalt else {
                    return
                }
                guard let batch = batches.first else {
                    notice = "This listing has no file to preview."
                    return
                }
                let value = try ProviderMappingClient.preview(profile: profile, context: context,
                                                              casePack: casePack, batch: batch, redaction: plan)
                // Payload and its counts are assigned together: a number with
                // no request behind it is not evidence of anything.
                self.preview = Preview(value: value, fileCount: batch.entries.count, batchCount: batches.count)
                self.leakedTerms = plan.isIdentity ? [] : plan.leaks(value.system + String(decoding: value.payload, as: UTF8.self))
            } catch {
                if !Task.isCancelled { self.show(error, operation: .providerProbe, fallback: .incompatible) }
            }
        }
    }

    func discoverMCP() {
        guard auxWork == nil else { return }
        capabilities = nil
        auxWork = Task {
            defer { auxWork = nil; if phase == .discoveringMCP { phase = .idle } }
            phase = .discoveringMCP
            let client = DEVONthinkReadOnlyClient()
            do {
                let found = try await client.discover()
                if !Task.isCancelled { capabilities = found }
            } catch {
                if !Task.isCancelled { show(error, operation: .discoverMCP, fallback: .unavailable) }
            }
            await client.close()
        }
    }

    func selectedCaseCount(for profile: MappingProfile) -> Int {
        casePack?.selected(for: profile).count ?? 0
    }

    // MARK: - Helpers

    /// The engine is cached, but a cache keyed on nothing would answer a second
    /// profile with the first profile's rules: `MappingEngine` binds a profile
    /// and a case pack at construction. The key is the pair it was built from,
    /// so switching profiles rebuilds and a repeat run reuses.
    private func engine(for profile: MappingProfile) -> MappingEngine? {
        let key = "\(profile.versionKey)|\(casePack?.versionKey ?? "no-case-pack")"
        if let engineCache, engineCache.key == key { return engineCache.engine }
        guard let casePack else {
            error = .unavailable
            notice = "The shipped CasePack could not be loaded, so no engine can be built."
            return nil
        }
        let built = MappingEngine(profile: profile, casePack: casePack,
                                  answerer: ProviderMappingClient(), workspace: workspace)
        engineCache = (key, built)
        return built
    }

    private func refreshRows() {
        guard let manifest else {
            rows = []
            exceptions = []
            return
        }
        let failures = outcome?.failures ?? [:]
        rows = manifest.entries.map { entry in
            MappingRow(sourceID: entry.sourceID, entry: entry, source: self.entry(with: entry.sourceID),
                       failure: failures[entry.sourceID],
                       candidates: context?.candidate(for: entry.sourceID) ?? [])
        }
        exceptions = Self.exceptionRows(manifest)
    }

    /// The same rows FormaCore writes into `exceptions.json`: one per blocked
    /// entry, with the reason the program recorded and the violation codes that
    /// name its own cause. `ManifestExport.Exceptions` builds these internally
    /// from a manifest, so the interface reads the identical fields from it.
    private static func exceptionRows(_ manifest: Manifest) -> [ExceptionRow] {
        let byPath = Dictionary(grouping: manifest.report.allViolations) { $0.instancePath }
        return manifest.entries
            .filter { $0.state == .hold || $0.state == .unknown || $0.state == .invalidated }
            .sorted { $0.relativePath < $1.relativePath }
            .map { entry in
                let violations = byPath[entry.relativePath] ?? []
                let conflicting = entry.fields.first { $0.status == .conflict }?.field
                let reason = entry.invalidatedReason
                    ?? conflicting.map { "conflict:\($0.rawValue)" }
                    ?? "evidence_incomplete"
                return ExceptionRow(sourceID: entry.sourceID, relativePath: entry.relativePath,
                                    state: entry.state, reason: reason,
                                    codes: Array(Set(violations.map(\.code))).sorted(),
                                    violations: violations)
            }
    }

    private func finishWork() {
        work = nil
        phase = .idle
    }

    private func show(_ error: any Error, operation: FormaDiagnostics.Operation, fallback: FormaError) {
        let safe = error as? FormaError ?? fallback
        FormaDiagnostics.failure(operation, safe)
        self.error = safe
    }

    // MARK: - Term persistence

    struct StoredTerm: Codable {
        let id: UUID
        let term: String
        let role: String
    }
}

private extension UserDefaults {
    func loadTerms(forKey key: String) -> [WorkspaceModel.RedactionTerm] {
        guard let data = data(forKey: key),
              let stored = try? JSONDecoder().decode([WorkspaceModel.StoredTerm].self, from: data) else { return [] }
        return stored.compactMap { row in
            guard let role = RedactionPlan.Role(rawValue: row.role) else { return nil }
            return WorkspaceModel.RedactionTerm(id: row.id, term: row.term, role: role)
        }
    }

    func save(terms: [WorkspaceModel.RedactionTerm], forKey key: String) {
        let stored = terms.map { WorkspaceModel.StoredTerm(id: $0.id, term: $0.term, role: $0.role.rawValue) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        set(data, forKey: key)
    }
}
