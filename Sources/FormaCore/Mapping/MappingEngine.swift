import CryptoKit
import Foundation

/// The seam between the engine and whatever answers a mapping request.
///
/// The engine is tested against a deterministic fake here, which is what lets
/// the batching, reference mapping, repair limit and hold semantics be proven
/// without credentials. A fake answer is never reported as real provider
/// verification: the live path is `ProviderMappingClient`, and its status is
/// recorded separately.
public protocol MappingAnswering: Sendable {
    func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                redaction: RedactionPlan) async -> MappingAttempt
}

extension ProviderMappingClient: MappingAnswering {
    public func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                       context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                       redaction: RedactionPlan) async -> MappingAttempt {
        await map(provider: provider, model: model, allowCloud: allowCloud, profile: profile, context: context,
                  casePack: casePack, batch: batch, redaction: redaction)
    }
}

public struct MappingRunRequest: Sendable {
    public let scope: SourceScope
    public let profile: MappingProfile
    public let context: ProjectContext
    public let entries: [SourceEntry]
    public let evidence: [UUID: [EvidenceRecord]]
    public let provider: ProbeProvider
    public let model: String
    public let allowCloud: Bool
    public let redaction: RedactionPlan
    public let entryLimit: Int

    public init(scope: SourceScope, profile: MappingProfile, context: ProjectContext, entries: [SourceEntry],
                evidence: [UUID: [EvidenceRecord]], provider: ProbeProvider, model: String, allowCloud: Bool,
                redaction: RedactionPlan = .none, entryLimit: Int = MappingPrompt.defaultEntryLimit) {
        self.scope = scope
        self.profile = profile
        self.context = context
        self.entries = entries
        self.evidence = evidence
        self.provider = provider
        self.model = model
        self.allowCloud = allowCloud
        self.redaction = redaction
        self.entryLimit = max(1, entryLimit)
    }
}

public struct MappingRunOutcome: Sendable {
    public let manifest: Manifest
    public let batches: Int
    public let requests: Int
    public let usage: MappingUsage
    public let modelID: String?
    /// Per-file provider failures, kept beside the manifest rather than inside
    /// it, because they describe the request rather than the document.
    public let failures: [UUID: FormaError]
    /// Answers that named an `entry_ref` the program never issued. They are
    /// counted and refused, never matched by name.
    public let refusedReferences: Int
}

/// Turns a listing, a context and an evidence registry into a validated
/// Manifest, per PLAN §6.1 and §7.
///
/// The engine holds no DEVONthink client: its only outbound dependency is
/// `MappingAnswering` and its only persistence and file-reading path is the
/// workspace actor. That is the structural half of "the mapper has no write
/// capability", and it is why a prompt-injected instruction to import a record
/// has nothing it could reach.
public actor MappingEngine {
    private let profile: MappingProfile
    private let casePack: CasePack
    private let answerer: any MappingAnswering
    private let workspace: SourceWorkspace

    public init(profile: MappingProfile, casePack: CasePack, answerer: any MappingAnswering,
                workspace: SourceWorkspace) {
        self.profile = profile
        self.casePack = casePack
        self.answerer = answerer
        self.workspace = workspace
    }

    public func run(_ request: MappingRunRequest) async -> MappingRunOutcome {
        let evidence = request.evidence
        var answers: [UUID: ProposalForEntry] = [:]
        var usage = MappingUsage()
        var requests = 0
        var failures: [UUID: FormaError] = [:]
        var modelID: String?
        var refused = 0

        // First pass over every batch.
        var state = BatchState(nextRef: 1)
        let first = Self.batches(from: request.entries, context: request.context, limit: request.entryLimit,
                                 state: &state)
        for var batch in Self.withEvidence(first, evidence: evidence) {
            let attempt = await answerer.answer(provider: request.provider, model: request.model,
                                                allowCloud: request.allowCloud, profile: request.profile,
                                                context: request.context, casePack: casePack, batch: batch,
                                                redaction: request.redaction)
            requests += attempt.requests
            usage = usage + attempt.usage
            modelID = attempt.modelID ?? modelID
            refused += merge(attempt: attempt, batch: &batch, into: &answers, failures: &failures)
            if Task.isCancelled { break }
        }

        var current = evidence
        var resolved = validate(request: request, answers: Array(answers.values), evidence: current)

        // One bounded re-ask: only entries that hold because no body evidence
        // exists yet, and only where reading the file is actually possible.
        let recoverable = Self.entriesNeedingEvidence(resolved, request: request, evidence: current)
        if !recoverable.isEmpty, !Task.isCancelled {
            let extracted = await extractEvidence(for: recoverable)
            // Registering the re-read rows is not optional: the manifest this
            // pass produces cites them, and a citation the registry cannot
            // resolve would make the stored revision unverifiable later. So
            // evidence the registry will not accept is not used at all: the
            // entry keeps the hold it already has and the reason is recorded,
            // instead of a second answer being built on rows nothing can read
            // back.
            var registered: [UUID: [EvidenceRecord]] = [:]
            for (id, records) in extracted {
                do {
                    try await workspace.recordEvidence(records, for: id)
                    registered[id] = records
                } catch {
                    failures[id] = error as? FormaError ?? .unavailable
                }
            }
            for (id, records) in registered { current[id] = records }
            let retryable = recoverable.filter { registered[$0.id] != nil }
            if !retryable.isEmpty {
                var retryState = BatchState(nextRef: 1)
                let retry = Self.batches(from: retryable, context: request.context, limit: request.entryLimit,
                                         state: &retryState)
                for var batch in Self.withEvidence(retry, evidence: current) {
                    let attempt = await answerer.answer(provider: request.provider, model: request.model,
                                                        allowCloud: request.allowCloud, profile: request.profile,
                                                        context: request.context, casePack: casePack, batch: batch,
                                                        redaction: request.redaction)
                    requests += attempt.requests
                    usage = usage + attempt.usage
                    modelID = attempt.modelID ?? modelID
                    refused += merge(attempt: attempt, batch: &batch, into: &answers, failures: &failures)
                    if Task.isCancelled { break }
                }
            }
            resolved = validate(request: request, answers: Array(answers.values), evidence: current)
        }

        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: request.scope.id,
            sourceRootID: request.scope.rootID, profile: request.profile,
            casePack: (casePack.id, casePack.version), modelProvider: request.provider.rawValue,
            modelID: modelID, contextRevision: request.context.revision,
            promptVersion: MappingPrompt.version, extractorVersion: EvidenceRegistry.extractorVersion,
            redactionVersion: request.redaction.isIdentity ? nil : RedactionPlan.version,
            inputDigest: request.context.inputDigest, contextDigest: Self.contextDigest(request.context),
            createdAt: .now, state: resolved.manifestState
        )
        let manifest = Manifest(envelope: envelope, entries: resolved.entries, report: resolved.report)
        return MappingRunOutcome(manifest: manifest, batches: first.count, requests: requests, usage: usage,
                                 modelID: modelID, failures: failures, refusedReferences: refused)
    }

    // MARK: - Batching

    struct BatchState {
        var nextRef: Int
    }

    /// Groups files by the candidate that claims them, so one candidate is
    /// answered in one context, then splits oversized groups. The group key is
    /// the candidate's own opaque id: two candidates can carry the same project
    /// key with different memberships, and grouping by key while attaching the
    /// first id found under that key would hand the model a reference whose
    /// membership does not contain the file it describes - which the validator
    /// correctly reports as a membership mismatch. Splitting never drops a
    /// file: every entry lands in exactly one batch, and all sub-batches of one
    /// candidate share the same versioned context.
    static func batches(from entries: [SourceEntry], context: ProjectContext, limit: Int,
                        state: inout BatchState) -> [MappingBatch] {
        let grouped = Dictionary(grouping: entries) { entry -> String in
            context.candidate(for: entry.id).sorted { $0.id < $1.id }.first?.id ?? "unaffiliated"
        }
        var batches: [MappingBatch] = []
        for key in grouped.keys.sorted() {
            let members = grouped[key]!.sorted { $0.relativePath < $1.relativePath }
            let candidateID = key == "unaffiliated" ? nil : key
            var start = 0
            while start < members.count {
                let end = min(start + limit, members.count)
                let chunk = Array(members[start..<end])
                start = end
                let refs = chunk.map { entry -> MappingEntryRef in
                    // An opaque batch-local reference: the path never travels
                    // inside the identifier, and the model never sees a source id.
                    defer { state.nextRef += 1 }
                    return MappingEntryRef(
                        ref: "e\(state.nextRef)", sourceID: entry.id, relativePath: entry.relativePath,
                        sizeBytes: entry.sizeBytes.map(Int.init),
                        extensionName: (entry.relativePath as NSString).pathExtension.lowercased(),
                        hydrationPending: entry.hydrationPending, provider: entry.provider.rawValue
                    )
                }
                batches.append(MappingBatch(id: "b\(batches.count + 1)", candidateID: candidateID, entries: refs,
                                            evidence: []))
            }
        }
        return batches
    }

    /// Attaches the registry rows a model may cite to each batch, limited to
    /// that batch's own sources.
    static func withEvidence(_ batches: [MappingBatch], evidence: [UUID: [EvidenceRecord]]) -> [MappingBatch] {
        batches.map { batch in
            let ids = Set(batch.entries.map(\.sourceID))
            let rows = evidence.filter { ids.contains($0.key) }.values.flatMap { $0 }
            return MappingBatch(id: batch.id, candidateID: batch.candidateID, entries: batch.entries,
                                evidence: rows)
        }
    }

    // MARK: - Answers

    @discardableResult
    private func merge(attempt: MappingAttempt, batch: inout MappingBatch, into answers: inout [UUID: ProposalForEntry],
                       failures: inout [UUID: FormaError]) -> Int {
        let refs = Dictionary(uniqueKeysWithValues: batch.entries.map { ($0.ref, $0.sourceID) })
        var refused = 0
        if let proposal = attempt.proposal {
            for entry in proposal.entries {
                // An unknown reference is refused rather than matched by name:
                // a model that invents an entry must not create a mapping.
                guard let sourceID = refs[entry.entryRef] else { refused += 1; continue }
                answers[sourceID] = ProposalForEntry(sourceID: sourceID, proposal: entry)
            }
        }
        guard let error = attempt.error else { return refused }
        for entry in batch.entries where answers[entry.sourceID] == nil {
            answers[entry.sourceID] = ProposalForEntry(sourceID: entry.sourceID, proposal: nil, failure: error)
            failures[entry.sourceID] = error
        }
        return refused
    }

    private func validate(request: MappingRunRequest, answers: [ProposalForEntry],
                          evidence: [UUID: [EvidenceRecord]]) -> ResolvedRun {
        let input = ValidationInput(profile: request.profile, context: request.context, entries: request.entries,
                                    evidence: evidence, proposals: answers)
        let result = ManifestValidator(input).validate()
        let counts = result.report.counts
        let state: ManifestEnvelope.ManifestState
        if counts.validated == 0 {
            state = .draft
        } else if counts.validated == counts.entries {
            state = .validated
        } else {
            state = .partiallyValidated
        }
        return ResolvedRun(entries: result.entries, report: result.report, manifestState: state)
    }

    struct ResolvedRun {
        let entries: [ManifestEntry]
        let report: ValidationReport
        let manifestState: ManifestEnvelope.ManifestState
    }

    /// Entries that could still be answered if their body were read: they hold
    /// because required evidence is missing, the file is present and local, and
    /// no usable content evidence exists for it yet.
    static func entriesNeedingEvidence(_ run: ResolvedRun, request: MappingRunRequest,
                                       evidence: [UUID: [EvidenceRecord]]) -> [SourceEntry] {
        let byID = Dictionary(uniqueKeysWithValues: request.entries.map { ($0.id, $0) })
        return run.entries.compactMap { entry in
            guard entry.state == .hold, entry.invalidatedReason == nil else { return nil }
            guard let source = byID[entry.sourceID], source.state == .present, !source.hydrationPending else {
                return nil
            }
            let records = evidence[entry.sourceID] ?? []
            let hasContent = records.contains { $0.source == .content && $0.isUsable }
            let missingRequired = entry.fields.contains {
                $0.value == nil && request.profile.fields[$0.field]?.requiredForValidated == true
            }
            return !hasContent && missingRequired ? source : nil
        }
    }

    private func extractEvidence(for entries: [SourceEntry]) async -> [UUID: [EvidenceRecord]] {
        var result: [UUID: [EvidenceRecord]] = [:]
        for entry in entries {
            guard let capture = try? await workspace.evidence(for: entry) else { continue }
            if let records = try? EvidenceRegistry.records(for: entry, capture: capture) {
                result[entry.id] = records
            }
            if Task.isCancelled { break }
        }
        return result
    }

    static func contextDigest(_ context: ProjectContext) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("context|\(context.revision)|\(context.inputDigest)\n".utf8))
        for candidate in context.candidates.sorted(by: { $0.id < $1.id }) {
            hasher.update(data: Data("\(candidate.id)|\(candidate.projectKey)|\(candidate.memberSourceIDs.count)\n".utf8))
        }
        return hasher.finalize().hexadecimalDigest
    }
}
