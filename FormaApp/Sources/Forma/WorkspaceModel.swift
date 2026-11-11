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
        case readingFile
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
            case .correcting: "Recording the correction…"
            case .readingFile: "Reading file…"
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
    @Published private(set) var registry: [String: EvidenceRecord] = [:]
    @Published private(set) var evidenceFailures: [UUID: FormaError] = [:]
    @Published private(set) var fileEvidence: SourceEvidence?
    @Published private(set) var exportSummary: ManifestExport.Summary?
    @Published private(set) var revalidation: ManifestExport.Revalidation?
    @Published private(set) var bundleURL: URL?
    @Published private(set) var casePack: CasePack?
    @Published private(set) var capabilities: DEVONthinkCapabilities?
    @Published private(set) var preview: ProviderMappingClient.Preview?
    @Published private(set) var leakedTerms: [String] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String?
    @Published var error: FormaError?

    @Published var selectedScopeID: UUID? {
        didSet {
            guard oldValue != selectedScopeID else { return }
            listing = nil
            context = nil
            contextIsStale = false
            manifest = nil
            outcome = nil
            refreshRows()
            Task { await self.reload() }
        }
    }

    @Published var selectedProfileID: String? {
        didSet {
            guard oldValue != selectedProfileID, !isRestoring else { return }
            defaults.set(selectedProfileID, forKey: Keys.profile)
            engine = nil
            Task { await self.reload() }
        }
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

    /// Cloud egress consent. Deliberately never persisted: it starts off at every
    /// launch and FormaCore's client refuses the request without it.
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
    private var engine: MappingEngine?
    private var work: Task<Void, Never>?
    private var fileWork: Task<Void, Never>?
    private var auxWork: Task<Void, Never>?
    private var isRestoring = true

    private static let store = UserDefaults.standard

    init(workspace: SourceWorkspace) {
        self.workspace = workspace
        let storedProvider = ProbeProvider.allCases.first { $0.rawValue == defaults.string(forKey: Keys.provider) }
            ?? .openAI
        provider = storedProvider
        modelID = defaults.string(forKey: Keys.model) ?? storedProvider.defaultModel
        entryLimit = (defaults.object(forKey: Keys.entryLimit) as? Int) ?? MappingPrompt.defaultEntryLimit
        redactionSalt = defaults.string(forKey: Keys.salt) ?? Self.defaultSalt
        redactionTerms = Self.store.loadTerms(forKey: Keys.terms)
        selectedProfileID = defaults.string(forKey: Keys.profile)
        selectedScopeID = UUID(uuidString: defaults.string(forKey: Keys.scope) ?? "")
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

    func record(for id: String) -> EvidenceRecord? { registry[id] }

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
        isRestoring = true
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
                selectedScopeID = scopes.first?.id
            }
        } catch {
            show(error, operation: .openWorkspace, fallback: .storage)
        }
        isRestoring = false
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
            let digest = ContextBuilder.inputDigest(scopeID: scope.id, profile: profile, entries: listing?.entries ?? [])
            let stored = try await workspace.storedContext(scope: scope, profile: profile, inputDigest: digest)
            guard scope.id == selectedScopeID, profile.profileID == selectedProfileID else { return }
            context = stored
            contextIsStale = false
            if let stored = try await workspace.currentManifest(scope: scope, profile: profile) {
                manifest = stored
                outcome = nil
                notice = "Restored revision \(stored.envelope.revision) of manifest \(stored.envelope.manifestID.uuidString.lowercased()) from workspace storage."
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
                let decision = try await workspace.reconcile(scope: scope, profile: profile)
                reconciliation = decision
                if let current = try await workspace.currentManifest(scope: scope, profile: profile) {
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
        phase = .readingFile
        fileWork = Task {
            defer {
                fileWork = nil
                if !phase.isBusy || phase == .readingFile { phase = .idle }
            }
            do {
                let result = extracting
                    ? try await workspace.evidence(for: entry)
                    : try await workspace.hash(for: entry)
                guard !Task.isCancelled else { return }
                fileEvidence = result
                if let rows = try? await workspace.evidenceRegistry(for: entry.id) {
                    merge(rows)
                }
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
        }
    }

    func cancelFileRead() {
        fileWork?.cancel()
    }

    /// Drops the file detail panel's evidence and stops its read. The registry
    /// keeps its rows: FormaCore owns them until a re-read replaces them.
    func clearFileEvidence() {
        fileWork?.cancel()
        fileWork = nil
        fileEvidence = nil
    }

    /// Loads the registry rows one manifest entry cites so a field chip can show
    /// its excerpt and locator, including after a restart.
    func loadEvidence(for sourceID: UUID) async {
        guard evidenceBySource[sourceID] == nil else { return }
        do {
            merge(try await workspace.evidenceRegistry(for: sourceID))
        } catch {
            if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
        }
    }

    private func merge(_ records: [EvidenceRecord]) {
        guard !records.isEmpty else { return }
        var copy = evidenceBySource
        var table = registry
        for record in records { table[record.id] = record }
        // FormaCore replaces a file's registry rows on every re-read, so the
        // per-source view follows it; the identifier table keeps older rows
        // that an older manifest revision still cites.
        for sourceID in Set(records.map(\.sourceID)) {
            copy[sourceID] = records.filter { $0.sourceID == sourceID }
        }
        evidenceBySource = copy
        registry = table
    }

    // MARK: - Mapping run

    /// Runs `MappingEngine` over the current listing, or over one selection when
    /// reprocessing exceptions. Evidence is registered through FormaCore first,
    /// so every citation a provider answer can make already exists in the store.
    /// `egress` is this run's consent, passed to FormaCore as
    /// `MappingRunRequest.allowCloud`. The local assessment path passes `false`
    /// and FormaCore's own client reports the refusal per file.
    func runMapping(sourceIDs: Set<UUID>? = nil, egress: Bool) {
        guard phase == .idle else { return }
        guard let scope = selectedScope, let profile = selectedProfile, let listing else {
            error = .unavailable
            notice = "Choose a source before mapping."
            return
        }
        guard let context else {
            error = .unavailable
            notice = "Build a project context first: FormaCore will not map files without one."
            return
        }
        guard let casePack else {
            error = .unavailable
            notice = "The shipped CasePack could not be loaded, so no request can be built."
            return
        }
        let targets: [SourceEntry]
        if let sourceIDs {
            targets = listing.entries.filter { sourceIDs.contains($0.id) }
            if targets.isEmpty {
                notice = "The selected files are no longer in this listing."
                return
            }
        } else {
            targets = listing.entries
        }
        guard let engine = engine(for: profile) else { return }

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
        // case pack is present whenever an engine could be built at all.
        let run = MappingRun(scopeID: scope.id, profile: profile, contextRevision: context.revision,
                             casePackVersion: casePack?.version ?? "unversioned",
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
                try? await self.workspace.finishMappingRun(id: run.id, state: .cancelled, batches: 0,
                                                           error: .cancelled)
                notice = "Cancelled during evidence capture · no provider request was made."
                return
            }
            self.merge(captured.values.flatMap { $0 })
            do {
                try await self.workspace.startMappingRun(run)
            } catch {
                self.show(error, operation: .providerProbe, fallback: .storage)
            }
            self.phase = .mapping
            let result = await engine.run(MappingRunRequest(scope: scope, profile: profile, context: context,
                                                             entries: targets, evidence: captured,
                                                             provider: provider, model: model,
                                                             allowCloud: consent, redaction: plan,
                                                             entryLimit: limit))
            if Task.isCancelled {
                try? await self.workspace.finishMappingRun(id: run.id, state: .cancelled,
                                                            batches: result.batches, error: .cancelled)
                notice = "Run cancelled after \(result.batches.formatted()) batches."
                return
            }
            var stored = result.manifest
            do {
                stored = try await self.workspace.saveManifest(result.manifest, scopeID: scope.id)
            } catch {
                self.show(error, operation: .providerProbe, fallback: .invalidOutput)
                notice = "FormaCore kept this result in memory only: the revision was not stored."
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
        let records = Array(registry.values)
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
                guard !Task.isCancelled else { return }
                self.merge(loadedRecords)
                self.manifest = loaded
                self.outcome = nil
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
                guard !Task.isCancelled else { return }
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

    /// Opens the sheet for one field, seeded with FormaCore's own value so the
    /// reviewer sees what they are overwriting rather than an empty box.
    func beginCorrection(sourceID: UUID, field: MetadataFieldID) {
        guard let row = rows.first(where: { $0.sourceID == sourceID }) else { return }
        let current = row.entry.metadata[field] ?? ""
        draft = CorrectionDraft(sourceID: sourceID, field: field, value: current,
                                citations: Set(row.entry.fields.first { $0.field == field }?.evidenceIDs ?? []))
    }

    func cancelCorrection() { draft = nil }

    /// Records a human decision. The engine, not this screen, decides whether
    /// it is supported: a click that cites nothing is stored as a refused
    /// attempt and changes no revision, and the notice has to say that instead
    /// of showing a checkmark for something that did not happen.
    func applyCorrection() {
        guard phase == .idle, let manifest, let scope = selectedScope, let profile = selectedProfile,
              let draft else { return }
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
                // Read back rather than trust the returned manifest: the store
                // decides the revision number, and the screen must show what it
                // actually wrote.
                self.manifest = try await workspace.currentManifest(scope: scope, profile: profile)
                    ?? applied.manifest
                self.draft = nil
                refreshRows()
                correctionHistory = try await workspace.corrections(manifestID: manifestID)
                notice = applied.violations.isEmpty
                    ? "Correction recorded as revision \(applied.manifest.envelope.revision.formatted())."
                    : "FormaCore refused this correction: \(applied.violations.map { $0.code }.joined(separator: " · ")). "
                        + "Nothing was changed, and the attempt is on the exceptions list."
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

    /// Builds the exact bytes one request would send, without sending anything.
    func previewEgress() {
        guard auxWork == nil else { return }
        guard let profile = selectedProfile, let context, let casePack, let listing else {
            error = .unavailable
            notice = "A preview needs a source, a profile and a stored project context."
            return
        }
        let limit = min(max(1, entryLimit), max(1, listing.entries.count))
        let refs = Array(listing.entries.filter { $0.state == .present }.sorted { $0.relativePath < $1.relativePath })
            .prefix(limit)
            .enumerated()
            .map { index, entry in
                MappingEntryRef(ref: "p\(index + 1)", sourceID: entry.id, relativePath: entry.relativePath,
                                sizeBytes: entry.sizeBytes.map(Int.init),
                                extensionName: (entry.relativePath as NSString).pathExtension.lowercased(),
                                hydrationPending: entry.hydrationPending, provider: entry.provider.rawValue)
            }
        guard !refs.isEmpty else {
            notice = "This listing has no present file to preview."
            return
        }
        let batch = MappingBatch(id: "preview", candidateID: nil, entries: refs, evidence: [])
        let plan = redaction
        preview = nil
        leakedTerms = []
        auxWork = Task {
            defer { auxWork = nil; if phase == .previewing { phase = .idle } }
            self.phase = .previewing
            do {
                let value = try ProviderMappingClient.preview(profile: profile, context: context,
                                                              casePack: casePack, batch: batch, redaction: plan)
                guard !Task.isCancelled else { return }
                self.preview = value
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

    private func engine(for profile: MappingProfile) -> MappingEngine? {
        if let engine { return engine }
        guard let casePack else {
            error = .unavailable
            notice = "The shipped CasePack could not be loaded, so no engine can be built."
            return nil
        }
        let built = MappingEngine(profile: profile, casePack: casePack,
                                  answerer: ProviderMappingClient(), workspace: workspace)
        engine = built
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
