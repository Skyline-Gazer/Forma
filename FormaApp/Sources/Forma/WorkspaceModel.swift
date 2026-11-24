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
        case readingEvidence
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
            case .readingEvidence: "Reading the file's evidence again…"
            case .discoveringMCP: "Discovering the MCP server…"
            case .previewing: "Building the request preview…"
            }
        }
    }

    // MARK: - Rows the areas display

    // `MappingRow`, `ExceptionRow` and `ClusterRow` are FormaCore's presentation
    // types (`Presentation/WorkspaceProjection.swift`), not nested app types.
    // They moved because the work that builds them moved with them: the rows
    // used to be rebuilt by `WorkspaceModel` inside a view body, which is code
    // `swift test` cannot compile, so the guarantee #151 asks for - the indexed
    // rebuild produces the same rows as the old per-render scan - could not be
    // asserted anywhere. The app still owns when they are rebuilt; FormaCore
    // owns how.

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
        static let customBaseURL = "mappingCustomBaseURL"
        static let plannerMode = "mappingPlannerMode"
        static let entryLimit = "mappingEntryLimit"
        static let salt = "mappingRedactionSalt"
        static let terms = "mappingRedactionTerms"
    }

    /// Which answerer a mapping run uses. `offline` is a deterministic draft, not
    /// a model: the manifest records `modelProvider = "offline"` and the run
    /// consumes no tokens. Switching modes never touches the stored provider,
    /// model or key of the other mode.
    /// The user-facing name lives in FormaCore's Presentation layer
    /// (`plannerModeLabel`) so it is one tested string; this enum only carries
    /// the persisted choice.
    enum PlannerMode: String {
        case offline
        case ai
    }

    @Published var plannerMode: PlannerMode {
        didSet {
            guard oldValue != plannerMode else { return }
            Self.store.set(plannerMode.rawValue, forKey: Keys.plannerMode)
            // The engine is built around the answerer, so a mode change must not
            // reuse the cached one.
            engineCache = nil
        }
    }

    /// Salt FormaCore itself uses for its identity plan, kept as the default so
    /// a term list added here behaves the same way as `RedactionPlan.none`.
    static let defaultSalt = "forma-default-salt"

    // MARK: - Published state

    @Published private(set) var scopes: [SourceScope] = []
    /// Readiness of every registered root, refreshed with the listing. Advisory
    /// only: it decides what to show and which fix to offer, never what to write.
    @Published private(set) var sourceStatuses: [UUID: SourceScopeStatus] = [:]
    /// The scanned listing. Assigning it rebuilds the identifier index, because
    /// every row, cluster file list and selection lookup below asks this
    /// collection a question - and doing that indexing here rather than in a
    /// computed property is the whole of the #151 audit item "recomputed every
    /// render".
    @Published private(set) var listing: SourceListing? {
        didSet {
            // Equality, not "the scan id moved": a rescan that changed one
            // file's snapshot keeps its scan id, its issue count and its
            // state, and an index that trusted those would answer the changed
            // file with the entry it replaced.
            guard listing != oldValue else { return }
            listingProjection = ListingProjection(entries: listing?.entries ?? [])
        }
    }
    @Published private(set) var profiles: [MappingProfile] = []
    /// The stored project context. Assigning it rebuilds the candidate index
    /// and the cluster panel's rows together, so neither is ever half-updated
    /// relative to the other.
    @Published private(set) var context: ProjectContext? {
        didSet {
            guard context?.revision != oldValue?.revision
                    || context?.inputDigest != oldValue?.inputDigest else { return }
            contextProjection = context.map(ContextProjection.init(context:))
            clusterRows = contextProjection?.rows ?? []
        }
    }
    @Published private(set) var contextIsStale = false
    /// The stored or produced manifest. Its derived tables are rebuilt by
    /// `refreshRows()`, which every assignment site already calls; a `didSet`
    /// here would compute the same rows twice per change and make the second
    /// computation look like the one that matters.
    @Published private(set) var manifest: Manifest?
    @Published private(set) var rows: [MappingRow] = []
    @Published private(set) var exceptions: [ExceptionRow] = []
    /// The panel's candidate table. It was a computed property that rebuilt
    /// every row, plus the two category rows, on every body evaluation; the
    /// Workspace table and the inspector both read it, so one render asked it
    /// twice. It now changes only where `context` changes.
    @Published private(set) var clusterRows: [ClusterRow] = []
    /// Every violation code the blocked rows carry, sorted: the filter's option
    /// list, which used to be a flatMap-set-sort inside the Exceptions body.
    @Published private(set) var exceptionCodes: [String] = []
    /// The blocked rows after the two filters. Stored rather than computed
    /// because the table, the "Shown N of M" line and the reprocess scope count
    /// all read it within one render, and each used to run the filter again.
    @Published private(set) var visibleExceptions: [ExceptionRow] = []
    @Published private(set) var outcome: MappingRunOutcome?
    @Published private(set) var reconciliation: ManifestReconciler.Decision?
    @Published private(set) var evidenceBySource: [UUID: [EvidenceRecord]] = [:]
    @Published private(set) var evidenceFailures: [UUID: FormaError] = [:]
    @Published private(set) var fileEvidence: SourceEvidence?
    @Published private(set) var exportSummary: ManifestExport.Summary?
    /// The Alpha dry run. Rebuilt on demand and dropped whenever the manifest
    /// changes, so a plan can never outlive the revision it describes.
    @Published private(set) var importPlan: ImportPlan?
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
        /// What the request was configured with at the click. These are shown
        /// beside the payload instead of the live fields, because the payload
        /// does not change when a field does: after a preview appears, reading
        /// the current values would pair one request's bytes with another
        /// request's settings.
        let entryLimit: Int
    }
    @Published private(set) var preview: Preview?
    @Published private(set) var leakedTerms: [String] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String?
    /// The codes of the last refused correction, published as data.
    ///
    /// The review screen used to recover them by parsing the sentence the
    /// model wrote into `notice`. A sentence is not an interface: it forced
    /// that notice to stay in one language and one shape, and left the desk
    /// guessing at what the sentence had meant. The codes are the codes now,
    /// and the notice can be written in the language the reader reads.
    @Published private(set) var lastRefusalCodes: [String] = []
    @Published var error: FormaError?

    /// The manifest the shell must not lose.
    ///
    /// Assigned by `reload()`, `runMapping`, `reconcile`, `loadBundle` and an
    /// accepted correction, none of them navigation events; the mirror is kept
    /// in step here because `refreshRows()` is the one thing every one of
    /// those paths already calls, so a new assignment site cannot forget it.
    /// Without it the shell's own record of "there is a manifest" would lag
    /// the manifest, and the #151 invariant that a switch keeps it would be
    /// asserted against a stale value.
    private func mirrorManifestInShellState() {
        shellState.manifestPresent = manifest != nil
    }

    @Published var selectedScopeID: UUID? {
        didSet {
            guard oldValue != selectedScopeID else { return }
            // The model is the only writer of this key: a view mirroring it on
            // appear would race the fallback in `restore()` and could persist a
            // scope id that no longer exists.
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
            invalidateEvidenceCache()
            refreshRows()
            // Everything a source switch owes - the area's selections, the
            // file detail and its read, the reload - is the effect list of one
            // event, decided by `FormaCore`'s transition rule. It used to be a
            // `didSet` body plus an `.onChange` in the shell doing the same
            // reset, which is two places to keep in step and one of them a
            // view; and it is *not* what an area switch does, which by the
            // same rule gets nothing.
            navigate(.scopeChanged(to: selectedScopeID))
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
            // A profile change re-reads, and nothing else: the file and cluster
            // selections still name files in the listing that has not changed,
            // so dropping them here would be the kind of side effect #151
            // spends its acceptance list telling navigation from work.
            navigate(.profileChanged(to: selectedProfileID))
        }
    }
    /// Starts a reload, unless `restore()` is assembling launch state: two
    /// reloads each write the listing, context, manifest and attempts after
    /// their own suspensions, and the last read to return would decide.
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

    /// The OpenAI-compatible server's base URL. Persisted like the model id:
    /// it is configuration, not consent. Every run derives its send target
    /// from this exact string through `EgressEndpoint.target`, so the wire URL
    /// can never be a host other than the one recorded in the grant, and the
    /// grant can never name a host the user did not save.
    @Published var customBaseURL: String {
        didSet {
            guard oldValue != customBaseURL else { return }
            defaults.set(customBaseURL, forKey: Keys.customBaseURL)
            // A stale preview was consented against the old target; the
            // identity the person approved changed with the URL.
            preview = nil
        }
    }

    @Published var entryLimit: Int {
        // Floored here so the field shows the number the engine honours: a zero
        // left in defaults by an older build would read as "0 files per batch"
        // while every batch still carried one file.
        didSet {
            let floored = max(1, entryLimit)
            guard floored == entryLimit else { entryLimit = floored; return }
            defaults.set(entryLimit, forKey: Keys.entryLimit)
        }
    }

    /// Cloud egress consent, never persisted: off at every launch, and
    /// FormaCore's client refuses the request without it.
    @Published var allowCloud = false

    // MARK: - Shell presentation state
    //
    // The scene-owned shell binds these so a person's place survives an area
    // switch, not merely a tab unmount: the shell never unmounts, and each
    // area's leading pane, table and inspector read these same values. They
    // are selections only - the model remains the single owner of everything
    // FormaCore produced.
    @Published var workspaceFileSelection: UUID?
    @Published var workspaceClusterSelection: String?
    @Published var mappingFileSelection: UUID?
    @Published var mappingEvidenceSelection: String?
    @Published var exceptionStateFilter: ExceptionFilterState = .all {
        didSet {
            guard exceptionStateFilter != oldValue else { return }
            refreshVisibleExceptions()
        }
    }
    @Published var exceptionCodeFilter: String? {
        didSet {
            guard exceptionCodeFilter != oldValue else { return }
            refreshVisibleExceptions()
        }
    }
    @Published var exceptionSelection: Set<UUID> = []
    /// Egress consent for the next reprocess only. It starts off, is read when
    /// the run fires and is cleared on acceptance, so no later action inherits
    /// it. The confirmation behind it is presentation of the same per-run
    /// contract the old titlebar checkbox carried.
    @Published var reprocessEgress = false

    /// The shell calls this when the scope changes: files and clusters belong
    /// to one listing, and these selections are the shell's, not the old
    /// view's private state.
    func resetAreaSelections() {
        workspaceFileSelection = nil
        workspaceClusterSelection = nil
    }

    /// Forgets the read cache for a listing that no longer exists.
    ///
    /// A scope switch already drops the listing, the context, the manifest and
    /// the rows (and with them every answer the cache can be asked about), but
    /// it has never dropped the evidence rows this session read - those stay
    /// in `evidenceBySource`, and this change does not alter that. The cache
    /// is emptied here for one reason: its keys are revisions of files in a
    /// listing that is gone, so nothing will ever ask for them again, and a
    /// session that visits a dozen sources would hold a dozen generations of
    /// excerpts it cannot reach.
    private func invalidateEvidenceCache() {
        evidenceCache.invalidateAll()
    }

    @Published var redactionSalt: String {
        didSet { defaults.set(redactionSalt, forKey: Keys.salt) }
    }

    @Published var redactionTerms: [RedactionTerm] {
        didSet { Self.store.save(terms: redactionTerms, forKey: Keys.terms) }
    }

    // MARK: - Handles

    /// Runs one blocking, file-or-keychain-touching operation away from the
    /// main actor and returns its result here.
    ///
    /// #151 audit item 4 was that these operations ran inside tasks that
    /// *inherited* this model's `@MainActor` isolation: `Task { … }` written in
    /// a main-actor class is a main-actor task, so a synchronous export or
    /// bundle read blocked the shell while pretending to be background work.
    /// Detaching is the smallest honest correction - the operation still
    /// finishes before anything is published, and publishing still happens
    /// only on this actor, so no view reads a value that is half-written.
    private static func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    // MARK: - Navigation state

    /// The shell's navigation state, as `FormaCore` declares it.
    ///
    /// The scene keeps the *authority* for each value - `@AppStorage` for the
    /// area, this model for the selections - and this copy is the audited
    /// mirror: every navigation event updates it before the shell acts, so
    /// what the tests in `ShellNavigationTests` assert about the transition
    /// function is what the running app carries. `switchArea` and the window's
    /// disappear are the only writers.
    private(set) var shellState = ShellNavigationState()

    /// The one interpreter of `FormaCore`'s navigation effects.
    ///
    /// `apply(_:to:)` says what an event may do; this is where the app agrees
    /// to do it, and it is deliberately short: an area switch has no effects,
    /// so there is nothing here it can reach. Adding a side effect to a switch
    /// would mean adding a case here as well, and the test that pins the rule
    /// would fail first.
    ///
    /// The cases call the methods the selections' `didSet` bodies already
    /// call - `cancelAll`, `resetAreaSelections`, `scheduleReload` - so there
    /// is one implementation of each behaviour, reached from one place, rather
    /// than a second path that could drift away from the first.
    func perform(_ effects: [ShellEffect]) {
        for effect in effects {
            switch effect {
            case .cancelInFlightWork:
                cancelAll()
            case .resetAreaSelections:
                resetAreaSelections()
            case .clearFileEvidence:
                clearFileEvidence()
            case .reload:
                scheduleReload()
            }
        }
    }

    /// Routes one shell event through the transition function, and then through
    /// the effect interpreter, in that order.
    ///
    /// The event is *asked* what it may do rather than the view being told what
    /// to skip: `onChange(of: storedArea)` used to be a place a fix could be
    /// added by accident, and the issue's failure mode - a switch that starts
    /// scanning, mapping or cancelling - was exactly such an accident, three
    /// tabs deep. Here the only thing an area switch can produce is the
    /// counter the transition function keeps and the signpost emitted below,
    /// because `apply(.areaChanged, to:)` returns no effects for all five areas.
    func navigate(_ event: ShellNavigationEvent) {
        if case .areaChanged = event {
            FormaPerf.record(PerfFact(stage: .areaSwitch))
        }
        let effects = apply(event, to: &shellState)
        // Two ledgers, deliberately not merged. `shellState.counters` is the
        // rule's own bookkeeping: what navigation *scheduled*. `workCounters`
        // is recorded at the entry points that actually ran (`reloadOnce`,
        // `scan`, a mapping run, a registry read), so what work *happened*.
        // Counting one reload in both would make a trace read two reloads;
        // keeping them apart is what lets the Mac recipe tell "the rule
        // scheduled nothing and the counters agree" from "the rule scheduled
        // nothing and something ran anyway", which is the difference between
        // the fix and the appearance of the fix.
        shellState.counters.record(effects: effects)
        perform(effects)
    }

    private let workspace: SourceWorkspace
    private let defaults = UserDefaults.standard
    /// The engine together with the identity it was built for. One value, so a
    /// cache and its validity key cannot be out of step with each other.
    private var engineCache: (key: String, engine: MappingEngine)?
    // MARK: D2 presentation state
    //
    // Three stored values, each rebuilt at the point its input changes rather
    // than at the point a view asks a question (#151 audit item 3). They are
    // not `@Published`: nothing renders them directly, and publishing a cache
    // would make the cache part of the invalidation storm it exists to remove.
    /// The current listing keyed by identifier, plus one path-ordered copy.
    private var listingProjection = ListingProjection(entries: [])
    /// The current context's candidate membership, labels and panel rows.
    private var contextProjection: ContextProjection?
    /// Registry rows already read for a (source, snapshot revision).
    private var evidenceCache = EvidenceCache()
    /// How often the capture loop may tell the whole shell it made progress.
    private let captureProgress = CaptureProgressCoalescing()
    /// Whether a reload is running, and whether one is owed after it.
    private var reloadCoalescing = ReloadCoalescing()
    /// Work-start counters, recorded at the entry points themselves.
    ///
    /// Read by the trace recipe (`docs/NAV-PERF-MAC-TRACE.md`): a Mac run that
    /// switches areas a hundred times must show `areaSwitches` at 100 and every
    /// other tally unchanged, which is the GUI-side half of the invariant the
    /// Core tests prove as a rule.
    private(set) var workCounters = ShellWorkCounters()
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
    /// The MCP client a discovery is using. Held so quitting can close the child
    /// instead of leaving it to the process teardown.
    private var discoveryClient: DEVONthinkReadOnlyClient?

    private static let store = UserDefaults.standard

    init(workspace: SourceWorkspace) {
        self.workspace = workspace
        // Reads go through the shared defaults instance rather than the
        // `defaults` property: Swift forbids touching `self` - and a property
        // read is a `self` use - until every stored property has a value, and
        // the assignments below are exactly what gives them one.
        let storedProvider = ProbeProvider.networkCases.first { $0.rawValue == Self.store.string(forKey: Keys.provider) }
            ?? .openAI
        provider = storedProvider
        modelID = Self.store.string(forKey: Keys.model) ?? storedProvider.defaultModel
        customBaseURL = Self.store.string(forKey: Keys.customBaseURL) ?? ""
        // `didSet` does not run for this assignment, so the floor is applied
        // here as well: a zero stored by an older build must not survive launch.
        entryLimit = max(1, (Self.store.object(forKey: Keys.entryLimit) as? Int)
                            ?? MappingPrompt.defaultEntryLimit)
        redactionSalt = Self.store.string(forKey: Keys.salt) ?? Self.defaultSalt
        redactionTerms = Self.store.loadTerms(forKey: Keys.terms)
        selectedProfileID = Self.store.string(forKey: Keys.profile)
        selectedScopeID = UUID(uuidString: Self.store.string(forKey: Keys.scope) ?? "")
        // Offline is the default because it is the only mode that works without
        // credentials; an existing choice is preserved verbatim.
        plannerMode = PlannerMode(rawValue: Self.store.string(forKey: Keys.plannerMode) ?? "") ?? .offline
        // The navigation mirror starts on the area and the selections the
        // window is about to open with, read straight from defaults rather
        // than through `self.defaults`: a switch away from *that* area is the
        // first event the counters will ever see, and a mirror seeded to the
        // workspace would report the very first real switch - Workspace to
        // Workspace, the case #151 names - as no switch at all, hiding the one
        // measurement the issue asks for.
        shellState = ShellNavigationState(
            area: AppArea.restored(from: Self.store.string(forKey: "shell.selectedArea")),
            scopeID: selectedScopeID,
            profileID: selectedProfileID,
            manifestPresent: false)
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
    /// screen resolves one per field chip per render. `merge` writes it from the
    /// same list it writes `evidenceBySource` from, for the sources that batch
    /// touched, so one id cannot show one excerpt here and another there.
    @Published private(set) var recordsByID: [String: EvidenceRecord] = [:]

    func record(for id: String) -> EvidenceRecord? { recordsByID[id] }

    func clusterKeys(for sourceID: UUID) -> [String] {
        contextProjection?.candidates(for: sourceID).map(\.projectKey) ?? []
    }

    /// What the Project column shows for one file.
    ///
    /// The Workspace table asks for the same source twice per row - the cell
    /// and its `help` - and used to answer both by filtering every candidate's
    /// membership set and sorting the result. The text is now assembled once
    /// per context revision, in `ContextProjection`, and a call here is one
    /// dictionary probe. The three strings that are *not* a join - "No
    /// context", "Unassigned", "Conflicted" - are still decided here, from the
    /// same inputs FormaCore's own judgement uses, so nothing about the copy
    /// changed.
    func clusterLabel(for sourceID: UUID) -> String {
        guard let contextProjection else { return "No context" }
        return contextProjection.label(for: sourceID) ?? "Unassigned"
    }

    func entry(with sourceID: UUID) -> SourceEntry? { listingProjection.entry(sourceID) }

    func files(in candidateID: String) -> [SourceEntry] {
        guard let contextProjection else { return [] }
        return listingProjection.files(in: contextProjection.members(ofCandidate: candidateID))
    }

    func files(in set: Set<UUID>) -> [SourceEntry] { listingProjection.files(in: set) }

    /// The files in one cluster row.
    ///
    /// `ClusterRow` and its two category identifiers are `FormaCore`'s now, for
    /// the same reason the other rows are: the text of the two category rows,
    /// the row order and the membership sets are all asserted in
    /// `WorkspaceProjectionTests` against the computation this replaced.
    func files(in row: ClusterRow) -> [SourceEntry] {
        switch row.kind {
        case .candidate: return files(in: row.id)
        case .unassigned: return listingProjection.files(in: context?.unassignedSourceIDs ?? [])
        case .conflicted: return listingProjection.files(in: context?.conflictedSourceIDs ?? [])
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
            // #151 audit item 4: shipped resources are bundle files. Reading
            // and decoding them here ran on the main actor during launch, in
            // front of the window's first draw, and the profile list is what
            // the rest of this function waits on. The read is detached; only
            // the assignment - the part that publishes - returns here.
            profiles = try await Self.offMain { try MappingProfile.shipped() }
        } catch {
            show(error, operation: .providerProbe, fallback: .unavailable)
        }
        if selectedProfile == nil { selectedProfileID = profiles.first?.profileID }
        do {
            casePack = try await Self.offMain { try CasePack.shipped() }
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
    ///
    /// #151 audit item 5 is fixed here rather than in `scheduleReload`: the
    /// guard against the launch burst of reloads already existed, but two
    /// *overlapping* reloads - scope and profile changed in quick succession -
    /// each read the listing, the context and the manifest, and each published
    /// on its own return, with the losing pass throwing away work it had
    /// already paid for at its `guard`. This wrapper runs one pass, remembers
    /// that the selection moved while it ran, and runs a second pass afterwards
    /// that sees the current selection. Nothing is dropped, and it is a
    /// coalescer rather than a debounce, so the last change is never starved.
    ///
    /// The item-4 half of the audit is *not* here: the store reads already run
    /// on FormaCore's actor, and `ContextBuilder.inputDigest` is a hash over
    /// entries already in memory, not a file. Detaching that would have been a
    /// change with no measured cause, and it is listed as measured-later in
    /// `docs/NAV-PERF-MAC-TRACE.md`.
    func reload() async {
        guard reloadCoalescing.request() else { return }
        while true {
            await reloadOnce()
            let owed = reloadCoalescing.complete()
            if Task.isCancelled {
                reloadCoalescing.cancel()
                return
            }
            if !owed { return }
            PerfTrace.emit(.progressCoalesced, count: reloadCoalescing.coalesced)
        }
    }

    private func reloadOnce() async {
        // Counted here rather than in `scheduleReload()`: the coalescer may
        // turn two requests into one pass, and the ledger that the trace
        // recipe reads has to say how many passes the store actually served.
        workCounters.record(.reload)
        await refreshSourceStatuses()
        guard let scope = selectedScope else {
            listing = nil
            context = nil
            manifest = nil
            refreshRows()
            return
        }
        do {
            let stage = FormaPerf.begin(.reloadListing)
            let result = try await workspace.listing(scope)
            FormaPerf.end(.reloadListing, stage)
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
            let stage = FormaPerf.begin(.reloadContext)
            let stored = try await workspace.storedContext(scope: scope, profile: profile, inputDigest: digest)
            FormaPerf.end(.reloadContext, stage)
            guard scope.id == selectedScopeID, profile.profileID == selectedProfileID else { return }
            context = stored
            contextIsStale = false
            let manifestStage = FormaPerf.begin(.reloadManifest)
            let current = try await workspace.currentManifest(scope: scope, profile: profile)
            FormaPerf.end(.reloadManifest, manifestStage)
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

    /// Probes every registered root. A failed probe is advisory: the listing is
    /// still shown, and the banner explains what is missing.
    func refreshSourceStatuses() async {
        guard let statuses = try? await workspace.scopeStatuses() else { return }
        sourceStatuses = Dictionary(uniqueKeysWithValues: statuses.map { ($0.scope.id, $0) })
    }

    func sourceStatus(for id: UUID) -> SourceScopeStatus? {
        sourceStatuses[id]
    }

    /// Hands an existing scope a folder again. The identity check happens in
    /// FormaCore: a different folder is refused, never swapped in silently.
    func reauthorize(_ scope: SourceScope, url: URL) async {
        do {
            switch try await workspace.reauthorize(scope: scope, with: url) {
            case .updated:
                notice = "Access to \(scope.displayName) was renewed."
                await reload()
            case .identityMismatch:
                // Not an error: a different folder is a new source, and saying so
                // is the only way the person can choose.
                notice = "That folder is not the source this entry was registered from. "
                    + "Add it as a new source instead."
            case .unknownScope:
                notice = "That source is no longer registered."
                scopes = (try? await workspace.scopes()) ?? scopes
            case .unusable(let error):
                show(error, operation: .registerSource, fallback: .invalidSource)
            }
        } catch {
            show(error, operation: .registerSource, fallback: .invalidSource)
        }
    }

    func scan() {
        guard phase == .idle, let scope = selectedScope else { return }
        workCounters.record(.scan)
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
        workCounters.record(.reconcile)
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
        workCounters.record(.buildContext)
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
                    // Opening the file for a *forced* re-read is the path that
                    // registers rows (`workspace.evidence(for:)` snapshots it
                    // first), so the set this merge published may be newer
                    // than anything the read cache holds for this revision.
                    // Dropping the source's keys costs one later registry read
                    // and buys the guarantee the chips cite what the store
                    // actually holds.
                    invalidateEvidenceCache(for: [entry.id])
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
    /// The read is now keyed by (source, snapshot revision) instead of being
    /// performed on every appearance, which is what #151's first audit line
    /// measured: `MappingView` re-read the registry each time the selection
    /// landed on a file, the read published two dictionaries, and every panel
    /// and the shell's own chrome re-rendered for rows the session already
    /// held.
    ///
    /// This replaces a comment that argued the opposite. It said a "already
    /// loaded" marker "would be a cache with no invalidation, and the chip
    /// would keep showing the excerpt the correction no longer cites". That was
    /// true of the marker it described, and it is still true of an unvalidated
    /// one. What makes this one safe is that it is not a marker: the key is the
    /// revision FormaCore's own rows are stamped with, every write path in this
    /// model calls `invalidate(sourceID:)` for the sources it touched, and a
    /// read that returns after such an invalidation is dropped rather than
    /// published (`EvidenceCache.publish`). `EvidenceCacheTests` pins all of
    /// that, including the capture-during-a-read race.
    func loadEvidence(for sourceID: UUID) async {
        guard let revision = evidenceRevision(for: sourceID) else {
            // No revision to key on: the file is not in this listing and no
            // manifest row cites it, so nothing here can say which snapshot the
            // rows would be read against. Read without caching rather than
            // invent a revision that a later, real one would collide with.
            PerfTrace.emit(.evidenceLoad, count: 0)
            do {
                merge(try await workspace.evidenceRegistry(for: sourceID))
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
            return
        }
        let key = EvidenceCacheKey(sourceID: sourceID, snapshotRevision: revision)
        let claim = evidenceCache.claim(key)
        if case .cached = claim {
            PerfTrace.emit(.evidenceCacheHit, count: evidenceCache.hits, shortCircuited: true)
            return
        }
        if case .coalesced = claim {
            // Another appearance of the same file already has the read running.
            // Its merge will publish for both; starting a second one is the
            // "duplicate work" #151 lists, and two merges of one batch is a
            // publish storm over a set of rows that has not changed.
            PerfTrace.emit(.evidenceLoadCoalesced, count: evidenceCache.coalesced, shortCircuited: true)
            return
        }
        guard case .read(let ticket) = claim else { return }
        workCounters.record(.evidenceLoad)
        PerfTrace.emit(.evidenceLoad, count: evidenceCache.misses)
        let stage = FormaPerf.begin(.evidenceLoad)
        do {
            let rows = try await workspace.evidenceRegistry(for: sourceID)
            FormaPerf.end(.evidenceLoad, stage)
            guard evidenceCache.publish(rows, against: ticket) else {
                // Something registered or corrected rows for this source while
                // this read was in flight. Publishing what this read saw would
                // be publishing a set that is already known to be behind, so it
                // is dropped: the capture path merged its own rows, and the
                // next appearance re-reads against the new key.
                PerfTrace.emit(.evidenceLoadStale, count: evidenceCache.stale, shortCircuited: true)
                return
            }
            merge(rows)
        } catch {
            evidenceCache.abandon(ticket)
            if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
        }
    }

    /// The snapshot revision a source's registry rows are keyed against.
    ///
    /// The listing is the authority while it is open, because it is what a
    /// mapping run and an extraction read. An imported bundle has no listing,
    /// so its manifest rows carry the revision instead; both are FormaCore's
    /// own numbers, never a count derived from how many rows are held.
    private func evidenceRevision(for sourceID: UUID) -> Int? {
        if let entry = listingProjection.entry(sourceID) { return Int(exactly: entry.snapshotRevision) }
        return manifest?.entries.first { $0.sourceID == sourceID }?.snapshotRevision
    }

    // MARK: - Evidence currency

    /// The snapshot a citation has to describe under the manifest in hand.
    ///
    /// A citation is accepted when it describes the snapshot the manifest
    /// entry is bound to, and refused when it describes an older one. The
    /// review screen asks the same question before the reviewer ticks a row,
    /// so a row that cannot be cited is never offered as if it could.
    func citationBinding(for sourceID: UUID) -> EvidenceSnapshotBinding? {
        guard let entry = rows.first(where: { $0.sourceID == sourceID })?.entry else { return nil }
        return EvidenceSnapshotBinding(revision: entry.snapshotRevision, fingerprint: entry.snapshotFingerprint)
    }

    /// Whether the file has moved past the manifest in hand.
    ///
    /// A file that changed since the run is a different document: every row
    /// read from the old one is out of date, including the rows the manifest
    /// itself cites, and the correction has to be made against the new file.
    func fileMovedSinceManifest(for sourceID: UUID) -> Bool {
        guard let binding = citationBinding(for: sourceID),
              let entry = listing?.entries.first(where: { $0.id == sourceID }) else { return false }
        return Int(entry.snapshotRevision) != binding.revision
            || entry.snapshotFingerprint != binding.fingerprint
    }

    /// Whether a registered row can still be cited for this source.
    func currency(of record: EvidenceRecord, for sourceID: UUID) -> EvidenceCurrency {
        guard let binding = citationBinding(for: sourceID) else { return .current }
        if fileMovedSinceManifest(for: sourceID) { return .expired }
        return EvidenceCurrency.currency(of: record, against: binding)
    }

    /// Re-reads a file's evidence and registers it under the snapshot it was
    /// read from.
    ///
    /// This is the recovery the review screen offers when the rows on screen
    /// describe an older snapshot: reading the file again produces rows for
    /// the current one. A selection that named rows the re-read replaced is
    /// dropped - keeping it would leave a checked row that cannot be cited.
    func rereadEvidence(for sourceID: UUID) {
        guard phase == .idle, let entry = listing?.entries.first(where: { $0.id == sourceID }) else {
            notice = "这份文件不在当前清单里，请重新扫描后再试。"
            return
        }
        phase = .readingEvidence
        notice = nil
        work = Task {
            defer { finishWork() }
            do {
                let records = try await workspace.captureEvidence(for: entry)
                guard !Task.isCancelled else { return }
                merge(records)
                invalidateEvidenceCache(for: [sourceID])
                if let scope = selectedScope, let refreshed = try? await workspace.listing(scope) {
                    listing = refreshed
                }
                if let draft, draft.sourceID == sourceID {
                    let current = Set(records.map(\.id))
                    self.draft?.citations = draft.citations.filter { current.contains($0) }
                }
                notice = fileMovedSinceManifest(for: sourceID)
                    ? "证据已重新读取（\(records.count.formatted()) 行）。清单已更新到新的快照，这份文件需要重新识别后才能修订。"
                    : "已重新读取证据（\(records.count.formatted()) 行）。请重新选择要引用的证据。"
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
        }
    }

    /// Folds freshly read rows into the per-source view. Rows are unioned by
    /// id rather than replacing a source's list: a capture that returns only
    /// what it just extracted must not hide the rows an older revision cites,
    /// because those rows are what makes an old manifest verifiable. When two
    /// reads carry one id, the later merge supplies the copy both views show -
    /// the store itself keeps the first content for an id (`insertEvidence`
    /// ignores a collision), so this is about which read reached the session
    /// last, not about two copies of one stored row disagreeing.
    ///
    /// The folding writes each published dictionary once. It used to assign
    /// `evidenceBySource` per source and `recordsByID` per row inside the loop,
    /// and both are `@Published` on the model every panel observes: a
    /// thousand-row registration was two thousand model-wide invalidations for
    /// one batch, which is the second audit line's "publishes what every panel
    /// observes" in its purest form. Same result, two publishes.
    private func merge(_ records: [EvidenceRecord]) {
        guard !records.isEmpty else { return }
        // Only the sources this batch touched are rebuilt. Order between two
        // reads cannot matter: `MappingStore.insertEvidence` writes with
        // `INSERT OR IGNORE` over an id that hashes the source, snapshot
        // revision, source and locator, so one id has one stored content.
        var bySource = evidenceBySource
        var index = recordsByID
        for sourceID in Set(records.map(\.sourceID)) {
            var byID: [String: EvidenceRecord] = [:]
            for record in bySource[sourceID] ?? [] where record.sourceID == sourceID {
                byID[record.id] = record
            }
            for record in records where record.sourceID == sourceID {
                byID[record.id] = record
            }
            let rows = byID.values.sorted { $0.id < $1.id }
            bySource[sourceID] = rows
            for row in rows { index[row.id] = row }
        }
        evidenceBySource = bySource
        recordsByID = index
    }

    /// Drops the read cache for sources whose rows may have just changed.
    ///
    /// Every path that can register a row calls this after its own merge: the
    /// capture batch of a mapping run, a forced re-read of one file, an
    /// accepted correction, and a bundle load that merges rows from another
    /// machine's store. Without it a chip could resolve a citation against the
    /// set read before the write, which is the failure mode the original
    /// no-cache comment named.
    private func invalidateEvidenceCache(for sourceIDs: some Sequence<UUID>) {
        let touched = Set(sourceIDs)
        guard !touched.isEmpty else { return }
        for sourceID in touched { evidenceCache.invalidate(sourceID: sourceID) }
        PerfTrace.emit(.evidenceLoad, count: evidenceCache.invalidations)
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
        workCounters.record(.mapping)
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
        // The mode decides both the answerer and the identity the run records:
        // an offline draft must never be written as a model's work.
        let offline = plannerMode == .offline
        let provider: ProbeProvider = offline ? .offline : self.provider
        let model = offline ? OfflinePlannerAnswerer.modelID : modelID
        // Nothing is sent in offline mode, so there is nothing to consent to.
        let consent = offline ? false : egress
        let limit = entryLimit
        let plan = redaction
        // Consent alone is not an authorization. Build one grant from the
        // approved data range, provider, model and redaction policy; FormaCore's
        // gate re-checks it against every wire request. The preview digest is
        // recorded for auditing, but the binding is `.dataRange`: a run re-reads
        // file bodies, so the preview is explicitly not a byte-level receipt.
        // The factory resolves the send target too: for a configured endpoint
        // the grant names the exact URL, and a missing or malformed Base URL
        // fails here - before an engine exists - with the text that explains it.
        let grant: EgressAuthorization?
        if consent {
            switch EgressAuthorization.mapping(
                provider: provider, model: model, customBaseURL: customBaseURL,
                previewDigest: preview?.value.digest,
                redactionVersion: MappingPrompt.redactionVersion(for: plan),
                identitySubstitution: plan.isIdentity) {
            case .success(let built): grant = built
            case .failure(let failure):
                error = failure
                if provider.requiresConfiguredEndpoint {
                    notice = "请先填写有效的 OpenAI-compatible Base URL（例如 http://127.0.0.1:11434/v1 或 https://host.example/v1）。"
                }
                return false
            }
        } else {
            grant = nil
        }
        guard let engine = engine(for: profile, authorization: grant) else { return false }
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
            // #151 audit item 2, the one this loop was: one `phase` write per
            // file, each an `objectWillChange` for a model every panel and the
            // shell's own status strip observe. Six files is six invalidations
            // and stays six here; a thousand-file listing was a thousand
            // whole-shell passes to draw a number nobody can read between two
            // frames. `CaptureProgressCoalescing` is a count-based bucket, not
            // a timer, so the same fixture publishes the same number of times
            // in CI and on a Mac, and the first and last file always speak.
            var published = 0
            for (index, entry) in targets.enumerated() {
                if Task.isCancelled { break }
                if captureProgress.shouldPublish(index: index, total: targets.count) {
                    self.phase = .capturingEvidence(done: index, total: targets.count)
                    published += 1
                }
                do {
                    captured[entry.id] = try await self.workspace.captureEvidence(for: entry)
                } catch {
                    // FormaCore registers what it can read. A file it cannot
                    // read simply has no rows for a provider answer to cite, and
                    // the validator records that as its own reason.
                    unread[entry.id] = error as? FormaError ?? .unavailable
                }
            }
            if targets.count > published {
                PerfTrace.emit(.progressCoalesced, count: targets.count - published, shortCircuited: true)
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
            // The first body read may calculate SHA-256 and append a new Source
            // snapshot, and FormaCore registers the captured evidence against
            // that *post-read* revision while the listing this run entered on
            // still describes the pre-read one. FormaCore's
            // `bindCapturedTargets` re-reads the authoritative listing - one
            // database read, no second user Scan - and hands back the
            // post-read entries a run must map, only evidence rows bound to
            // the snapshot that listing reports, and the failures in between.
            let binding: SourceWorkspace.PostCaptureTargetBinding
            do {
                binding = try await self.workspace.bindCapturedTargets(targets, captured: captured,
                                                                       readFailures: unread, scope: scope,
                                                                       profile: profile, context: context)
            } catch {
                if !Task.isCancelled, scope.id == self.selectedScopeID {
                    self.show(error, operation: .providerProbe, fallback: .unavailable)
                }
                return
            }
            guard !Task.isCancelled, scope.id == self.selectedScopeID,
                  profile.profileID == self.selectedProfileID else { return }
            // The capture registered rows for these sources at their current
            // revision. Any read that was in flight when it happened is now
            // known to be behind, and the key this revision maps to must be
            // re-read rather than answered from the set held before the write.
            invalidateEvidenceCache(for: captured.keys)
            let currentTargets: [SourceEntry]
            let currentEvidence: [UUID: [EvidenceRecord]]
            switch binding {
            case .listingChanged(let currentListing):
                self.listing = currentListing
                self.notice = "The source list changed during evidence capture. Review the files before mapping again."
                return
            case .contextStale(let currentListing):
                // The stale-snapshot half of the reviewer's feedback: this is
                // a moved structure, not unread files, and the fix is a fresh
                // project context, not another scan of the same files.
                self.listing = currentListing
                self.contextIsStale = true
                self.notice = "The source structure changed. Build a fresh project context before mapping."
                return
            case .bound(let entries, let evidence, let failures, let currentListing):
                currentTargets = entries
                currentEvidence = evidence
                unread = failures
                self.listing = currentListing
                self.evidenceFailures = failures
                self.merge(evidence.values.flatMap { $0 })
            }
            do {
                try await self.workspace.startMappingRun(run)
            } catch {
                // Only the panel this run belongs to may be told it failed.
                guard scope.id == self.selectedScopeID, profile.profileID == self.selectedProfileID else { return }
                self.show(error, operation: .providerProbe, fallback: .storage)
            }
            self.phase = .mapping
            let result = await engine.run(MappingRunRequest(scope: scope, profile: profile, context: context,
                                                             entries: currentTargets, evidence: currentEvidence,
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

    /// Cancels the model's tasks and closes any MCP child they were using.
    ///
    /// Cancellation is not completion: the scan row keeps `scanning` and the next
    /// launch reports it as interrupted. Nothing here records success.
    ///
    /// The counter is the half that matters for #151. The audit's failure was
    /// that `cancelAll` sat in a view that unmounted on every tab switch, so
    /// switching areas stopped work nobody asked to stop. D1 moved the call to
    /// the scene-owned shell; this is what a trace reads to prove the move
    /// held: `cancellations` must stay at zero across a run of area switches
    /// and rise only when the window closes or a Cancel button is pressed.
    func cancelAll() {
        workCounters.record(.cancel)
        // A cancelled capture stops wherever it was: rows were registered for
        // the files it had reached and not for the rest, and the batch it
        // would have merged never runs. The read cache cannot tell which keys
        // it read from before that point, so it is emptied rather than trusted;
        // `ReloadCoalescing` likewise forgets a pass that was owed, because the
        // person asked for the work to stop, not for it to be re-run later.
        reloadCoalescing.cancel()
        invalidateEvidenceCache()
        work?.cancel()
        fileWork?.cancel()
        auxWork?.cancel()
        if let client = discoveryClient {
            discoveryClient = nil
            Task { await client.close() }
        }
    }

    // MARK: - Export, load and revalidate

    // MARK: - Alpha dry run

    /// Builds the import plan for the current manifest.
    ///
    /// No write path exists in this build: the plan is built with
    /// `writeToolsAvailable == false`, no import authorization and unobserved
    /// target facts, so every row is `blocked` or `deferred` for a reason the
    /// view can explain. That is the honest state of the product, not a UI
    /// failure state.
    func buildImportPlan() {
        guard phase == .idle else { return }
        guard let manifest, let profile = selectedProfile else {
            importPlan = nil
            notice = "An import plan needs a manifest and a profile."
            return
        }
        importPlan = ImportPlanner.plan(
            manifest: manifest,
            profile: profile,
            observations: ImportPlanner.Observations(sourceRoot: nil, listing: listing),
            authorization: nil,
            capability: ImportCapabilityFacts(writeToolsAvailable: false, readbackAvailable: false),
            targetObserved: false)
    }

    /// Writes the plan as JSON so it can be attached to a review without the app.
    ///
    /// Encoding and write are the slow half of this click and used to run on
    /// the main actor; the notice that names the file is what has to happen
    /// here. The guard stays before the suspension, so a second click while a
    /// write is running still sees the plan it was asked for.
    func writeImportPlan(to directory: URL) async {
        guard let plan = importPlan else {
            notice = "Build the import plan first."
            return
        }
        do {
            let name: String = try await Self.offMain {
                let data = try FormaJSON.encoder(pretty: true).encode(plan)
                let url = directory.appendingPathComponent("import-plan-r\(plan.manifestRevision).json")
                try data.write(to: url, options: .atomic)
                return url.lastPathComponent
            }
            notice = "Wrote \(name): a dry-run plan that lists local file names, "
                + "so treat it as private data rather than a sanitized artifact."
        } catch {
            show(error as? FormaError ?? .storage, operation: .readEvidence, fallback: .storage)
        }
    }

    func export(to directory: URL) {
        guard phase == .idle, let manifest else {
            if manifest == nil { notice = "There is no manifest to export yet." }
            return
        }
        workCounters.record(.export)
        let plan = redactionTerms.isEmpty ? nil : redaction
        let sourceIDs = Set(manifest.entries.map(\.sourceID))
        phase = .exporting
        work = Task {
            defer { finishWork() }
            do {
                // Registered rows, not the ones this session happens to have
                // opened. A bundle whose manifest cites evidence the export
                // never carried contradicts itself: the violation only shows up
                // when somebody revalidates it offline, on another machine,
                // after the "Exported N files" notice was dismissed.
                let grouped = try await workspace.registeredEvidence(for: sourceIDs)
                let records = grouped.values.flatMap { $0 }
                guard !Task.isCancelled else { return }
                // #151 audit item 4: `ManifestExport.export` creates the bundle
                // directory, writes the manifest, every evidence file and the
                // archive, then reads them back. It is synchronous because the
                // validator is a pure function over bytes; running it here, on
                // the main actor, inside a task that inherited this model's
                // isolation, is what made Export stall the whole shell. The
                // work is detached, and only the summary - the value that is
                // published - returns to this actor.
                let stage = FormaPerf.begin(.export)
                let summary = try await Self.offMain {
                    try ManifestExport.export(manifest: manifest, evidence: records,
                                              to: directory, redaction: plan)
                }
                FormaPerf.end(.export, stage)
                PerfTrace.emit(.export, count: summary.files.count)
                guard !Task.isCancelled else { return }
                exportSummary = summary
                bundleURL = directory.appendingPathComponent(summary.manifestID, isDirectory: true)
                // Stated as what happened, and no more: whether the bundle holds
                // every row its manifest cites is answered when the bundle is
                // revalidated, where absent ids surface as `evidence_not_found`.
                // An export cannot assert that from its own return value, which
                // counts files and a revision.
                let files = summary.files.count.formatted()
                let revision = summary.revision.formatted()
                notice = "Exported \(files) files for revision \(revision)."
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
        // #151 audit item 4, in its plainest form: a stat call and a
        // `Data(contentsOf:)` for the manifest and for every evidence row, on
        // the main actor, in the click handler, before the task that was
        // supposed to be the background work even started. Which bundle it is,
        // whether the manifest exists and what the bytes decode to are all
        // answered off-actor now; this actor publishes, and only after its own
        // cancellation checks.
        phase = .loadingManifest
        work = Task {
            defer { finishWork() }
            do {
                let loaded = try await Self.offMain { try Self.readBundle(at: url) }
                // The bundle's entries are combined with the current listing
                // when rows are rebuilt, so this is only meaningful while the
                // source selected at the click is still selected: a switch
                // during the read would pair a foreign manifest with another
                // source's rows and present the mixture as one table.
                guard !Task.isCancelled, selectedScopeID == boundScope,
                      selectedProfileID == boundProfile else { return }
                self.merge(loaded.records)
                // Rows from another machine's store are now in this session's
                // view, and the cache holds registry sets read before they
                // arrived: keys whose rows may have just grown are dropped
                // rather than trusted.
                invalidateEvidenceCache(for: loaded.records.map(\.sourceID))
                self.manifest = loaded.manifest
                self.outcome = nil
                // A loaded bundle carries no local attempt history: those rows
                // live in the store of whoever exported it, and showing this
                // session's stale list beside a foreign manifest would
                // attribute decisions to the wrong reviewer.
                self.correctionHistory = []
                self.correctionHistoryState = .offlineBundle
                self.bundleURL = loaded.bundle
                self.revalidation = nil
                self.notice = "Loaded revision \(loaded.manifest.envelope.revision.formatted()) from \(loaded.bundle.path) · "
                    + "\(loaded.manifest.entries.count.formatted()) entries · "
                    + "\(loaded.records.count.formatted()) evidence rows offline."
                self.refreshRows()
            } catch let failure as BundleReadFailure {
                guard !Task.isCancelled else { return }
                switch failure.reason {
                case .noManifest:
                    error = .unavailable
                    notice = "\(failure.bundle.path) has no \(ManifestExport.manifestFile), so it is not a Forma export bundle."
                case .undecodable:
                    FormaDiagnostics.failure(.readEvidence, .unavailable)
                    error = .unavailable
                    notice = "\(failure.manifestURL.lastPathComponent) is not a Forma manifest FormaCore can decode."
                }
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
        }
    }

    /// What a bundle read produced, gathered away from the main actor.
    private struct BundleContents: Sendable {
        let bundle: URL
        let manifestURL: URL
        let manifest: Manifest
        let records: [EvidenceRecord]
    }

    /// A folder that holds no manifest, or bytes that are not one, reported
    /// with the paths the notice shows. Kept apart from `FormaError` because
    /// the message is a statement about a folder rather than a code FormaCore
    /// returns, and because a read that happens off the main actor has to
    /// carry its own explanation back rather than reach for `self`.
    private struct BundleReadFailure: Error, Sendable {
        enum Reason: Sendable {
            case noManifest
            case undecodable
        }

        let reason: Reason
        let bundle: URL
        let manifestURL: URL
    }

    /// Reads a bundle's manifest and evidence rows from disk.
    ///
    /// Runs on a detached priority: these are the two largest synchronous
    /// reads the app performs, and the listing they describe can be a
    /// thousand entries with one evidence file per citation.
    private nonisolated static func readBundle(at url: URL) throws -> BundleContents {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let bundle = isDirectory ? url : url.deletingLastPathComponent()
        let manifestURL = isDirectory ? bundle.appendingPathComponent(ManifestExport.manifestFile) : url
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BundleReadFailure(reason: .noManifest, bundle: bundle, manifestURL: manifestURL)
        }
        do {
            let manifest = try FormaJSON.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            var records: [EvidenceRecord] = []
            let evidenceURL = bundle.appendingPathComponent(ManifestExport.evidenceFile)
            if FileManager.default.fileExists(atPath: evidenceURL.path) {
                records = try FormaJSON.decode([EvidenceRecord].self, from: Data(contentsOf: evidenceURL))
            }
            return BundleContents(bundle: bundle, manifestURL: manifestURL, manifest: manifest, records: records)
        } catch {
            throw BundleReadFailure(reason: .undecodable, bundle: bundle, manifestURL: manifestURL)
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
        workCounters.record(.revalidate)
        phase = .revalidating
        work = Task {
            defer { finishWork() }
            do {
                // #151 audit item 4, the same shape as `export(to:)`: reading
                // the bundle back and verifying every digest is file I/O with
                // a signature check per file, and it ran on the main actor
                // because this task inherited the model's isolation.
                let stage = FormaPerf.begin(.revalidate)
                let result = try await Self.offMain { try ManifestExport.revalidate(at: bundleURL) }
                FormaPerf.end(.revalidate, stage)
                PerfTrace.emit(.revalidate, count: result.violations.count)
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

    /// The draft whose Record click is being written, or nil.
    ///
    /// Not `phase`, even though `phase` is `.correcting` during the same
    /// window: one model-level phase is shared with scanning, mapping, export
    /// and preview, and a cancelled write only returns it to `.idle` when its
    /// task reaches its `defer`, which can be after the reviewer has opened
    /// another field's sheet. Keying on the draft says which sheet is waiting.
    @Published private(set) var recordingDraftID: String?
    @Published private(set) var correctionHistory: [CorrectionRecord] = []
    /// What `correctionHistory` currently describes.
    ///
    /// The same list can mean four different things depending on how it got
    /// that way, and a boolean could name two of them at best: not read yet,
    /// read from this store, belonging to a bundle whose history is on another
    /// machine, or a read that failed and left only the click's own row.
    enum CorrectionHistoryState {
        /// Nothing has been read for the manifest now on screen.
        case notRead
        /// The rows below are everything the local store holds for it, and an
        /// empty list is then a fact about the manifest.
        case fromStore
        /// The manifest came from an exported bundle: its attempts live in the
        /// store of whoever exported it and cannot be read from here at all.
        case offlineBundle
        /// The read for this manifest's attempts failed. The list holds the
        /// decision just made and nothing else, so it is neither the full
        /// history nor an empty one, and must not be presented as either.
        case readFailed
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

    func cancelCorrection() {
        // Cancelling while the write is in flight has to stop the write, not
        // just hide the sheet: the reviewer's next signal would otherwise be a
        // result notice for a decision they believe they abandoned.
        if recordingDraftID == draft?.id { cancelWork() }
        draft = nil
    }

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
        let draftID = draft.id
        phase = .correcting
        recordingDraftID = draftID
        work = Task {
            defer { recordingDraftID = nil; finishWork() }
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
                // undo it: what follows only refines the screen, and an error
                // there used to conceal a correction that had succeeded.
                let message = applied.violations.isEmpty
                    ? "修订已保存为第 \(applied.manifest.envelope.revision.formatted()) 版。"
                    : "本次修订未通过校验，内容未改动；这次尝试已记入诊断列表。"
                // The codes travel as themselves. The sentence above says what
                // happened in the reader's language; the codes are what the
                // review screen turns into an actionable reason.
                self.lastRefusalCodes = applied.violations.map(\.code)
                // The published manifest is not re-fetched. "The current manifest
                // for this scope and profile" is a different question - it can
                // answer with another manifest that happens to be newer - and
                // `applyCorrection` already returns the one the store wrote. The
                // history read is `do`/`catch` rather than `try?` because it
                // already answers optionally, and the two would look alike below.
                var attempts: [CorrectionRecord]?
                do { attempts = try await workspace.corrections(manifestID: manifestID) }
                catch { attempts = nil }
                guard !Task.isCancelled, scope.id == selectedScopeID,
                      profile.profileID == selectedProfileID else { return }
                self.manifest = applied.manifest
                // A correction can carry evidence FormaCore registered for the
                // field it re-decided, and it writes a new manifest revision
                // whose rows cite ids this session may not have read yet. The
                // chip that opens next must resolve against the registry as it
                // is now, which is the exact failure the old no-cache comment
                // described; this line is the invalidation that lets the cache
                // exist.
                invalidateEvidenceCache(for: [draft.sourceID])
                // Close the sheet this click came from, and only that one: the
                // reviewer may have opened another field while this write was
                // running, and clearing whatever draft is current would throw
                // away a decision being typed now. `self.` is load-bearing -
                // the bare `draft` above is this click's unwrapped draft.
                // A refused correction must leave the editor open with the
                // user's value and cited rows intact. Closing the sheet on
                // failure discards the only actionable context and forces the
                // reviewer to re-enter the same information. Only a revision
                // actually published by FormaCore dismisses the editor.
                if applied.violations.isEmpty, self.draft?.id == draftID {
                    self.draft = nil
                }
                refreshRows()
                if let history = attempts {
                    correctionHistory = history
                    correctionHistoryState = .fromStore
                } else {
                    // The click's own row is shown, and the panel says the rest
                    // is missing because the read failed - not that nothing has
                    // been read, which is a different claim and would present a
                    // one-row list as a complete history.
                    correctionHistory = [applied.correction]
                    correctionHistoryState = .readFailed
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
    /// Stores the provider key in the Keychain.
    ///
    /// Made `async` for #151 audit item 4: a SecItem write is an XPC round
    /// trip to a system daemon, and it used to block the main actor for the
    /// length of it - the one thing a Settings pane should never do while the
    /// shell is redrawing behind it. The caller stays on the main actor; only
    /// the write is detached, and the answer comes back here so the notice and
    /// the field's own "saved" mark are published where views can see them.
    @discardableResult func saveKey(_ key: String) async -> Bool {
        let chosenProvider = provider
        do {
            // The client is built inside the detached work rather than here:
            // it wraps the Keychain store and the egress authoriser, and none
            // of that belongs on the main actor for the length of one write.
            try await Self.offMain {
                try ProviderMappingClient().saveKey(key, for: chosenProvider)
            }
            notice = "API key saved in Keychain for \(chosenProvider.displayName)."
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
    /// The batch limit and the redaction plan are taken at the click, and
    /// nothing is published unless the panel still describes that same request
    /// when the evidence read returns - so a preview cannot show one request
    /// while the fields beside it configure another.
    func previewEgress() {
        guard auxWork == nil else { return }
        guard let scope = selectedScope, let profile = selectedProfile, let context, let casePack,
              let listing else {
            error = .unavailable
            notice = "A preview needs a source, a profile and a stored project context."
            return
        }
        let limit = entryLimit
        let plan = redaction
        let contextRevision = context.revision
        preview = nil
        auxWork = Task {
            defer { auxWork = nil; if phase == .previewing { phase = .idle } }
            self.phase = .previewing
            do {
                let rows = try await workspace.registeredEvidence(for: Set(listing.entries.map(\.id)))
                let batches = MappingEngine.plannedBatches(from: listing.entries, context: context,
                                                          limit: limit, evidence: rows)
                // The panel must still describe the request that was built.
                guard !Task.isCancelled, scope.id == selectedScopeID,
                      profile.profileID == selectedProfileID,
                      contextRevision == self.context?.revision,
                      limit == entryLimit, plan == redaction else {
                    return
                }
                guard let batch = batches.first else {
                    notice = "This listing has no file to preview."
                    return
                }
                let value = try ProviderMappingClient.preview(profile: profile, context: context,
                                                              casePack: casePack, batch: batch, redaction: plan)
                // Payload, its counts and the configuration it was built under
                // are assigned together: a number with no request behind it is
                // not evidence of anything, and a request without the settings
                // that produced it cannot be checked by whoever reads it.
                self.preview = Preview(value: value, fileCount: batch.entries.count, batchCount: batches.count,
                                       entryLimit: limit)
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
            discoveryClient = client
            do {
                let found = try await client.discover()
                if !Task.isCancelled { capabilities = found }
            } catch {
                if !Task.isCancelled { show(error, operation: .discoverMCP, fallback: .unavailable) }
            }
            await client.close()
            if discoveryClient === client { discoveryClient = nil }
        }
    }

    func selectedCaseCount(for profile: MappingProfile) -> Int {
        casePack?.selected(for: profile).count ?? 0
    }

    // MARK: - Helpers

    /// The engine is cached, but a cache keyed on nothing would answer a second
    /// profile with the first profile's rules - or a second run with the first
    /// run's authorization. The key names the profile, the case pack and the
    /// grant, so a revoked or changed scope cannot reuse a client built under
    /// the old one.
    private func engine(for profile: MappingProfile,
                        authorization: EgressAuthorization?) -> MappingEngine? {
        let key = "\(plannerMode.rawValue)|\(profile.versionKey)|\(casePack?.versionKey ?? "no-case-pack")"
            + "|\(authorization?.id ?? "no-egress")"
        if let engineCache, engineCache.key == key { return engineCache.engine }
        guard let casePack else {
            error = .unavailable
            notice = "The shipped CasePack could not be loaded, so no engine can be built."
            return nil
        }
        let answerer: any MappingAnswering
        switch plannerMode {
        case .offline:
            // Deterministic, no socket, no key: the manifest records `offline`.
            answerer = OfflinePlannerAnswerer()
        case .ai:
            answerer = authorization.map { ProviderMappingClient(authorization: $0) } ?? ProviderMappingClient()
        }
        let built = MappingEngine(profile: profile, casePack: casePack,
                                  answerer: answerer, workspace: workspace)
        engineCache = (key, built)
        return built
    }

    private func refreshRows() {
        // A plan describes one manifest revision. Any change to the manifest
        // invalidates it, and a stale plan is worse than none: it would show a
        // target and a verdict for records that no longer exist in this shape.
        importPlan = nil
        let stage = FormaPerf.begin(.refreshRows)
        defer { FormaPerf.end(.refreshRows, stage) }
        guard let manifest else {
            rows = []
            exceptions = []
            exceptionCodes = []
            visibleExceptions = []
            mirrorManifestInShellState()
            PerfTrace.emit(.refreshRows, count: 0)
            return
        }
        // #151 audit item 3. This used to map every manifest entry through
        // `self.entry(with:)`, a linear scan of the listing - a thousand
        // entries therefore cost about half a million comparisons per rebuild,
        // on the main actor, and the rebuild runs after every run, correction,
        // reconciliation and bundle load. The candidate lookup per entry was a
        // second scan of the same size. Both are dictionary probes now, and
        // the shapes they produce are `FormaCore`'s, asserted equal to the
        // old computation in `WorkspaceProjectionTests`.
        rows = WorkspaceProjection.mappingRows(manifest: manifest,
                                              failures: outcome?.failures ?? [:],
                                              listing: listingProjection,
                                              context: contextProjection)
        exceptions = WorkspaceProjection.exceptionRows(manifest: manifest)
        exceptionCodes = WorkspaceProjection.exceptionCodes(rows: exceptions)
        refreshVisibleExceptions()
        mirrorManifestInShellState()
        PerfTrace.emit(.refreshRows, count: rows.count)
    }

    /// Applies the two Exceptions filters to the stored rows.
    ///
    /// The view used to run the same filter on every body evaluation, next to
    /// a code list it also recomputed each time; both now read stored values
    /// that change only when the rows or the filters do. The filter itself is
    /// `WorkspaceProjection.filteredExceptions`, so the rule the panel follows
    /// is the rule the test asserts.
    private func refreshVisibleExceptions() {
        visibleExceptions = WorkspaceProjection.filteredExceptions(
            exceptions,
            state: exceptionStateFilter.state,
            code: exceptionCodeFilter)
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

    // MARK: - Review Desk state (#146; additive)
    //
    // The desk's cursor and filter live on the shared model like the other
    // areas' selections do: switching to 诊断 and back keeps reviewing the
    // same file. Nothing here recomputes a value FormaCore owns; the queue
    // only buckets the rows the mapping already published.

    /// The file being reviewed in the desk queue.
    @Published var deskFileSelection: UUID?

    /// The desk's triage bucket (待处理 / 已验证 / 需关注).
    @Published var deskTriage: DeskTriage = .pending

    /// The revision a Save & Next armed at: the cursor may move only when the
    /// manifest revision grows past this baseline (ReviewDeskFlow.advances).
    /// A refused correction changes nothing, so the baseline simply stays.
    @Published var deskBaselineRevision: Int?

    /// The visible desk queue: current rows bucketed by the triage filter,
    /// in manifest order.
    var deskQueue: [MappingRow] {
        rows.filter { FormaCore.deskTriage(for: $0.entry.state) == deskTriage }
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
