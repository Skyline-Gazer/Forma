import Foundation

/// What a stand-in does with one call.
///
/// The knobs are the failure modes the runner has to survive, not a general
/// scripting language: a stand-in either answers, answers incompletely, answers
/// wrongly, answers with a conflict, answers where the reference answer is empty,
/// fails, hangs past its deadline, or reports nothing at all. A test states one of
/// those; it does not need a way to compute one.
public struct SubstituteAnswer: Sendable {
    /// Slots the stand-in leaves empty even though the reference answer has a
    /// value - a withheld slot, which is a miss rather than an error.
    public var withhold: Set<MetadataFieldID>
    /// Slots whose value is replaced by a different value of the same shape. The
    /// replacement has to stay type-valid on purpose: a value the profile would
    /// reject reads as withheld, and the two are different measurements.
    public var misstate: Set<MetadataFieldID>
    /// Slots filled where the reference answer has nothing - the invented fill
    /// PLAN §8.2's 空漏填 side is about.
    public var invent: Set<MetadataFieldID>
    /// Slots whose entry carries a conflict, which the validator turns into a
    /// `contradicted` judgement and which may never auto-publish.
    public var contradict: Set<MetadataFieldID>
    public var confidence: DecisionConfidence
    /// A request-level failure: no proposal, one failed attempt. Used to prove a
    /// run keeps the record in the denominator instead of dropping it.
    public var failure: FormaError?
    /// How long the stand-in actually takes before answering. A wait rather than a
    /// number, so that a per-request timeout is tested against a real deadline and
    /// not against a latency field the answerer reported.
    public var delay: Duration
    /// The latency the stand-in reports to telemetry. Separate from `delay`
    /// because they are different facts: one is when the answer came back, the
    /// other is what a report would print.
    public var reportedLatencyMilliseconds: Int
    /// Counts the stand-in reports. A nil column means it reported nothing for
    /// that column, which telemetry must publish as absent rather than zero.
    public var usage: TokenUsage
    /// A first-token observation, or nil when nothing observed one. Nil is the
    /// honest default: a non-streaming answer's total latency is not a TTFT.
    public var firstTokenMilliseconds: Int?

    public init(withhold: Set<MetadataFieldID> = [], misstate: Set<MetadataFieldID> = [],
                invent: Set<MetadataFieldID> = [], contradict: Set<MetadataFieldID> = [],
                confidence: DecisionConfidence = .high, failure: FormaError? = nil,
                delay: Duration = .zero, reportedLatencyMilliseconds: Int = 0,
                usage: TokenUsage = .unavailable, firstTokenMilliseconds: Int? = nil) {
        self.withhold = withhold
        self.misstate = misstate
        self.invent = invent
        self.contradict = contradict
        self.confidence = confidence
        self.failure = failure
        self.delay = delay
        self.reportedLatencyMilliseconds = reportedLatencyMilliseconds
        self.usage = usage
        self.firstTokenMilliseconds = firstTokenMilliseconds
    }

    /// The faithful stand-in: every reference value, cited, high confidence, no
    /// usage. A run driven by it exercises the harness end to end and produces a
    /// manifest the validator accepts - and a report that refuses every quality
    /// claim, because the answers came from here.
    public static let faithful = SubstituteAnswer()
}

/// A deterministic stand-in for the mapping provider.
///
/// The seam is `MappingAnswering`: the engine and this runner cannot tell a
/// stand-in from a live client, which is what makes batching, reference mapping,
/// validation and the manifest path testable without credentials. What the rest of
/// the system *can* tell is `isSubstitute`, and that is the only difference that
/// matters downstream - every quality claim is refused while it is true.
///
/// Nothing here reaches the network. A run that passes a stand-in never opens a
/// socket, never loads a key and never needs consent, so the P3-A authorisation
/// (合成数据与确定性替身) is the whole of what it needs.
public struct SubstituteAnswerer: MappingAnswering {
    /// The reference answer each source is supposed to reproduce, indexed by the
    /// source id the harness assigned. The stand-in answers from the gold record
    /// rather than from the batch text because that is what deterministic means
    /// here: the same inputs always produce the same answer, and the answer is
    /// stated by the harness instead of inferred from a prompt.
    private let bySource: [UUID: GoldRecord]
    private let answers: [UUID: SubstituteAnswer]
    private let fallback: SubstituteAnswer

    public init(references: [String: GoldRecord], answers: [UUID: SubstituteAnswer] = [:],
                fallback: SubstituteAnswer = .faithful) {
        var index: [UUID: GoldRecord] = [:]
        for record in references.values {
            index[EvaluationFixture.sourceID(for: record.recordID)] = record
        }
        self.bySource = index
        self.answers = answers
        self.fallback = fallback
    }

    public var isSubstitute: Bool { true }

    public func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                       context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                       redaction: RedactionPlan) async -> MappingAttempt {
        // A cancelled run must not answer: a proposal returned after cancellation
        // would let a batch the caller abandoned reach the manifest.
        guard !Task.isCancelled else {
            return Self.refusal(error: .cancelled, usage: .unavailable, latency: 0, ttft: nil, requests: 0)
        }
        // The behaviour is per source, and a batch is the unit the answerer is
        // called for, so the batch's first entry decides it. A test that needs
        // per-record behaviour runs with `entryLimit: 1`, which is also the
        // configuration where one request per record is the honest description.
        let behaviour = answers[batch.entries.first?.sourceID ?? UUID()] ?? fallback
        if behaviour.delay > .zero {
            do {
                try await Task.sleep(for: behaviour.delay)
            } catch {
                return Self.refusal(error: .cancelled, usage: .unavailable, latency: 0, ttft: nil, requests: 0)
            }
        }
        guard !Task.isCancelled else {
            return Self.refusal(error: .cancelled, usage: .unavailable, latency: 0, ttft: nil, requests: 0)
        }
        if let failure = behaviour.failure {
            return Self.refusal(error: failure, usage: behaviour.usage,
                                latency: behaviour.reportedLatencyMilliseconds,
                                ttft: behaviour.firstTokenMilliseconds, requests: 1)
        }

        var entries: [ProposalEntry] = []
        for item in batch.entries {
            guard let record = bySource[item.sourceID] else {
                // A source the harness never described. Refusing the batch is the
                // honest answer: guessing a mapping for an unknown file is exactly
                // what the validator exists to stop.
                return Self.refusal(error: .unavailable, usage: behaviour.usage,
                                    latency: behaviour.reportedLatencyMilliseconds,
                                    ttft: behaviour.firstTokenMilliseconds, requests: 1)
            }
            entries.append(Self.proposal(for: record, ref: item.ref, candidateID: batch.candidateID,
                                         behaviour: behaviour))
        }
        return MappingAttempt(proposal: MappingProposal(batchID: batch.id, entries: entries),
                              usage: Self.mappingUsage(behaviour.usage),
                              latencyMilliseconds: behaviour.reportedLatencyMilliseconds,
                              requests: 1, rateLimitRetries: 0,
                              timeToFirstTokenMilliseconds: behaviour.firstTokenMilliseconds)
    }

    // MARK: - Answer construction

    private static func proposal(for record: GoldRecord, ref: String, candidateID: String?,
                                 behaviour: SubstituteAnswer) -> ProposalEntry {
        let sourceID = EvaluationFixture.sourceID(for: record.recordID)
        let fingerprint = EvaluationFixture.fingerprint(for: record.recordID)
        var metadata = MetadataValues.allUnknown
        var citations: [EvidenceCitation] = []
        var unknown: Set<MetadataFieldID> = []

        for field in MetadataFieldID.allCases {
            if behaviour.withhold.contains(field) {
                unknown.insert(field)
                continue
            }
            let expected = EvaluationFixture.expected(record, field)
            let value: String?
            if behaviour.invent.contains(field) {
                value = Self.invented(for: field)
            } else if behaviour.misstate.contains(field) {
                value = expected.map { Self.mistaken($0, field: field) }
            } else {
                value = expected
            }
            guard let value else {
                unknown.insert(field)
                continue
            }
            metadata[field] = value
            if let row = try? Self.row(field: field, value: value, sourceID: sourceID,
                                       fingerprint: fingerprint) {
                citations.append(EvidenceCitation(field: field, evidenceID: row.id))
            }
        }

        var conflicts: [ProposalConflict] = []
        for field in behaviour.contradict.sorted(by: { $0.rawValue < $1.rawValue }) {
            conflicts.append(ProposalConflict(field: field, detail: "与第 3 页的记载相互矛盾"))
        }

        // A candidate the batch was built for is the only reference the stand-in
        // may name: the batch is the context's own unit, and inventing another
        // candidate would be a membership claim nobody made.
        return ProposalEntry(
            entryRef: ref,
            projectAssociation: candidateID.map { ProposalAssociation(candidateRef: $0, state: .confirmed) },
            documentCategory: metadata[.documentcategory],
            documentType: metadata[.documenttype],
            metadata: metadata,
            evidence: citations,
            unknownFields: unknown,
            conflicts: conflicts,
            confidence: behaviour.confidence,
            reasoning: "deterministic stand-in for \(record.recordID)")
    }

    /// A value of the field's own shape, used when the stand-in answers wrongly or
    /// invents a slot. Shape matters: a year-shaped value is the only kind that can
    /// produce a `wrong` verdict for a year slot, because anything else is rejected
    /// by the profile and counted as a withhold instead.
    static func invented(for field: MetadataFieldID) -> String {
        switch field {
        case .completionyear: return "2001"
        case .biddeadline: return "2001-01-01"
        default: return "编造值-\(field.rawValue)"
        }
    }

    static func mistaken(_ value: String, field: MetadataFieldID) -> String {
        switch field {
        case .completionyear:
            let year = Int(value) ?? 2026
            return String(year == 9_999 ? 1_000 : year + 1)
        case .biddeadline:
            return value == "2001-01-01" ? "2001-01-02" : "2001-01-01"
        default:
            return "错误值-\(value)"
        }
    }

    private static func row(field: MetadataFieldID, value: String, sourceID: UUID,
                            fingerprint: String) throws -> EvidenceRecord {
        let locator = EvaluationFixture.locator(for: field, length: value.count)
        let id = try EvidenceRegistry.identifier(
            sourceID: sourceID, snapshotRevision: EvaluationFixture.snapshotRevision, source: .content,
            locator: locator, relativePath: nil)
        return EvidenceRecord(id: id, sourceID: sourceID, snapshotRevision: EvaluationFixture.snapshotRevision,
                              snapshotFingerprint: fingerprint, source: .content, locator: locator,
                              relativePath: nil, excerpt: value, extractionStatus: .ok,
                              extractorVersion: EvidenceRegistry.extractorVersion,
                              createdAt: EvaluationFixture.fixtureDate)
    }

    private static func mappingUsage(_ usage: TokenUsage) -> MappingUsage {
        MappingUsage(input: usage.input, output: usage.output, cacheRead: usage.cacheRead,
                     cacheCreation: usage.cacheCreation)
    }

    private static func refusal(error: FormaError, usage: TokenUsage, latency: Int, ttft: Int?,
                                requests: Int) -> MappingAttempt {
        MappingAttempt(proposal: nil, error: error, usage: mappingUsage(usage),
                       latencyMilliseconds: latency, requests: requests,
                       timeToFirstTokenMilliseconds: ttft)
    }
}