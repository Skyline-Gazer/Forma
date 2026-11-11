import Foundation
import Testing

@testable import FormaCore

/// A deterministic stand-in for a provider.
///
/// It exists to prove the engine's own rules - batching, reference mapping,
/// refusal of invented references, bounded re-ask, cancellation and consent -
/// without credentials. Nothing here is evidence about a real model: the live
/// path is `ProviderMappingClient`, and its status is recorded separately.
struct FakeAnswerer: MappingAnswering {
    let respond: @Sendable (MappingBatch, Int) -> MappingAttempt
    private let counter: BatchCounter

    init(counter: BatchCounter = BatchCounter(),
         respond: @escaping @Sendable (MappingBatch, Int) -> MappingAttempt) {
        self.counter = counter
        self.respond = respond
    }

    func calls() async -> Int { await counter.count() }

    func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                redaction: RedactionPlan) async -> MappingAttempt {
        let index = await counter.add()
        return respond(batch, index)
    }
}

actor BatchCounter {
    private var seen = 0
    func add() -> Int {
        let current = seen
        seen += 1
        return current
    }

    func count() -> Int { seen }
}

/// Builds a schema-shaped answer for one batch.
func proposalText(batch: MappingBatch, citingEvidence: Bool = true,
                  mutate: (@escaping (inout [String: Any]) -> Void) = { _ in }) -> String {
    var entries: [[String: Any]] = []
    for item in batch.entries {
        var metadata: [String: Any?] = [:]
        for field in MetadataFieldID.allCases { metadata[field.rawValue] = nil }
        metadata["documentcategory"] = "01_招标文件"
        metadata["documenttype"] = "Tender Announcement"
        metadata["projectname"] = "示例项目_2026"
        metadata["completionyear"] = "2026"
        let content = batch.evidence.filter { $0.source == .content }.prefix(4).map {
            ["field": "documentcategory", "evidence_id": $0.id]
        }
        let path = batch.evidence.filter { $0.source == .path }.map {
            ["field": "projectname", "evidence_id": $0.id]
        }
        let year = batch.evidence.filter { $0.source == .content && ($0.excerpt ?? "").contains("2026") }.map {
            ["field": "completionyear", "evidence_id": $0.id]
        }
        let type = batch.evidence.filter { $0.source == .content && ($0.excerpt ?? "").contains("公告") }.map {
            ["field": "documenttype", "evidence_id": $0.id]
        }
        let cited: [[String: String]]
        if citingEvidence { cited = (content + path + year + type).prefix(8).map { $0 } }
        else { cited = [] }
        entries.append([
            "entry_ref": item.ref,
            "project_association": ["candidate_ref": batch.candidateID as Any, "state": "confirmed"],
            "document_category": "01_招标文件",
            "document_type": "Tender Announcement",
            "metadata": metadata,
            "evidence": cited,
            "unknown_fields": ["issuer", "bidderentity", "department", "salesowner", "endcustomer",
                               "biddeadline", "tenderreference", "bsdcode"],
            "conflicts": [],
            "confidence": "medium",
            "reasoning": "正文含招标公告与项目名称。",
        ])
    }
    var document: [String: Any] = ["schema_version": "1.0", "batch_id": batch.id, "entries": entries]
    mutate(&document)
    guard let data = try? JSONSerialization.data(withJSONObject: document) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

func decodedProposal(_ text: String) -> MappingProposal? {
    try? JSONDecoder().decode(MappingProposal.self, from: Data(text.utf8))
}

@Suite("Mapping engine")
struct MappingEngineTests {
    private struct Fixture {
        let source: SourceFixture
        let workspace: SourceWorkspace
        let scope: SourceScope
        let entries: [SourceEntry]
        let profile: MappingProfile
        let context: ProjectContext
        let evidence: [UUID: [EvidenceRecord]]
    }

    private func prepared() async throws -> Fixture {
        let fixture = try SourceFixture()
        _ = try fixture.write("tender notice 示例项目_2026 公告", at: "示例项目_2026/01_招标/公告.pdf")
        _ = try fixture.write("bid body", at: "示例项目_2026/02_投标/技术标.pdf")
        _ = try fixture.write("other notice", at: "别的项目_2025/公告.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        let profile = try MappingProfile.projectArchive()
        let context = ContextBuilder.build(
            ContextBuilderInput(scopeID: scope.id, profile: profile, entries: listing.entries), revision: 1
        )
        var evidence: [UUID: [EvidenceRecord]] = [:]
        for item in listing.entries {
            let capture = try await workspace.hash(for: item)
            evidence[item.id] = try EvidenceRegistry.records(for: item, capture: capture)
        }
        return Fixture(source: fixture, workspace: workspace, scope: scope, entries: listing.entries,
                       profile: profile, context: context, evidence: evidence)
    }

    private func engine(_ fixture: Fixture, answerer: FakeAnswerer) async throws -> MappingEngine {
        MappingEngine(profile: fixture.profile, casePack: try CasePack.shipped(), answerer: answerer,
                      workspace: fixture.workspace)
    }

    @Test("every entry lands in exactly one batch and references stay unique")
    func batchingCoversEverything() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        var state = MappingEngine.BatchState(nextRef: 1)
        let batches = MappingEngine.batches(from: fixture.entries, context: fixture.context, limit: 2,
                                            state: &state)
        let covered = batches.flatMap(\.entries)
        #expect(covered.count == fixture.entries.count, "splitting must not drop a file")
        #expect(Set(covered.map(\.ref)).count == covered.count)
        #expect(Set(covered.map(\.sourceID)) == Set(fixture.entries.map(\.id)))
        #expect(batches.allSatisfy { $0.entries.count <= 2 })
        // No reference carries a path fragment: the model must not learn the
        // layout through an identifier.
        #expect(covered.allSatisfy { !$0.ref.contains("/") })
    }

    @Test("a well-formed answer produces a manifest with no execution authority")
    func validatedMapping() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        let answerer = FakeAnswerer { batch, _ in
            MappingAttempt(proposal: decodedProposal(proposalText(batch: batch)), modelID: "fake-model", requests: 1)
        }
        let run = MappingRunRequest(scope: fixture.scope, profile: fixture.profile, context: fixture.context,
                                    entries: fixture.entries, evidence: fixture.evidence,
                                    provider: .anthropic, model: "fake", allowCloud: true)
        let outcome = await (try await engine(fixture, answerer: answerer)).run(run)
        #expect(outcome.manifest.entries.count == fixture.entries.count)
        #expect(outcome.requests == outcome.batches)
        #expect(outcome.refusedReferences == 0)
        #expect(outcome.modelID == "fake-model")
        #expect(outcome.manifest.envelope.grantsExecution == false)
        let packVersion = try CasePack.shipped().version
        #expect(outcome.manifest.envelope.casePackVersion == packVersion)
        #expect(outcome.manifest.envelope.contextRevision == fixture.context.revision)
        let counts = outcome.manifest.report.counts
        #expect(counts.validated + counts.hold + counts.unknown == fixture.entries.count)
        let data = try FormaJSON.encode(outcome.manifest, pretty: true)
        let violations = try ArtifactSchemaValidator.manifest.violations(data)
        #expect(violations.isEmpty, "engine output must satisfy the artifact schema: \(violations.map { $0.code })")
    }

    @Test("an invented entry reference is refused, never matched by name")
    func inventedReference() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        let answerer = FakeAnswerer { batch, _ in
            let text = proposalText(batch: batch) { document in
                guard var list = document["entries"] as? [[String: Any]] else { return }
                var extra = list[0]
                extra["entry_ref"] = "e9999"
                list.append(extra)
                document["entries"] = list
            }
            return MappingAttempt(proposal: decodedProposal(text), requests: 1)
        }
        let run = MappingRunRequest(scope: fixture.scope, profile: fixture.profile, context: fixture.context,
                                    entries: fixture.entries, evidence: fixture.evidence,
                                    provider: .anthropic, model: "fake", allowCloud: true)
        let outcome = await (try await engine(fixture, answerer: answerer)).run(run)
        #expect(outcome.refusedReferences >= 1)
        #expect(outcome.manifest.entries.count == fixture.entries.count,
                "a refused reference must not create a mapping")
    }

    @Test("a provider failure leaves entries unknown with a recorded reason")
    func providerFailure() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        let answerer = FakeAnswerer { _, _ in MappingAttempt(proposal: nil, error: .credentialMissing, requests: 0) }
        let run = MappingRunRequest(scope: fixture.scope, profile: fixture.profile, context: fixture.context,
                                    entries: fixture.entries, evidence: fixture.evidence,
                                    provider: .openAI, model: "fake", allowCloud: true)
        let outcome = await (try await engine(fixture, answerer: answerer)).run(run)
        #expect(outcome.manifest.entries.allSatisfy { $0.state == .unknown })
        #expect(outcome.failures.count == fixture.entries.count)
        #expect(outcome.manifest.envelope.state == .draft)
        #expect(outcome.manifest.report.allViolations.contains { $0.code.hasPrefix("provider_") })
    }

    @Test("without consent nothing is asked and every entry stays unknown")
    func consentGate() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        let client = ProviderMappingClient(session: URLSession(configuration: .ephemeral),
                                           keyStore: FailingKeyStore())
        let engine = MappingEngine(profile: fixture.profile, casePack: try CasePack.shipped(), answerer: client,
                                   workspace: fixture.workspace)
        let run = MappingRunRequest(scope: fixture.scope, profile: fixture.profile, context: fixture.context,
                                    entries: fixture.entries, evidence: fixture.evidence,
                                    provider: .openAI, model: "gpt-4o-mini", allowCloud: false)
        let outcome = await engine.run(run)
        #expect(outcome.requests == 0)
        #expect(outcome.failures.count == fixture.entries.count)
        #expect(outcome.failures.values.allSatisfy { $0 == .unauthorized })
    }

    @Test("a missing body triggers at most one bounded re-ask")
    func boundedReAsk() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        // No evidence at all on the first pass: every entry holds for lack of
        // body evidence, which is the only case worth asking about twice.
        let answerer = FakeAnswerer { batch, _ in
            MappingAttempt(proposal: decodedProposal(proposalText(batch: batch, citingEvidence: false)),
                           requests: 1)
        }
        let run = MappingRunRequest(scope: fixture.scope, profile: fixture.profile, context: fixture.context,
                                    entries: fixture.entries, evidence: [:],
                                    provider: .anthropic, model: "fake", allowCloud: true)
        let outcome = await (try await engine(fixture, answerer: answerer)).run(run)
        let asked = await answerer.calls()
        #expect(asked >= outcome.batches)
        #expect(asked <= outcome.batches * 2, "the re-ask must be bounded, got \(asked) calls")
        #expect(outcome.manifest.entries.allSatisfy { !$0.eligibleForAutoExecution })
    }

    @Test("a cancelled run stops asking")
    func cancellation() async throws {
        let fixture = try await prepared()
        defer { fixture.source.cleanUp() }
        let answerer = FakeAnswerer { _, _ in MappingAttempt(proposal: nil, error: .cancelled, requests: 0) }
        let engine = try await self.engine(fixture, answerer: answerer)
        let run = MappingRunRequest(scope: fixture.scope, profile: fixture.profile, context: fixture.context,
                                    entries: fixture.entries, evidence: fixture.evidence,
                                    provider: .anthropic, model: "fake", allowCloud: true)
        let task = Task { await engine.run(run) }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.manifest.entries.allSatisfy { $0.state == .unknown })
    }
}

struct FailingKeyStore: ProviderKeyStore {
    func save(_ key: String, for provider: ProbeProvider) throws {}
    func load(for provider: ProbeProvider) throws -> String? {
        throw FormaError.credentialMissing
    }
}
