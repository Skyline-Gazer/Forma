import Foundation
import Testing

@testable import FormaCore

/// The offline runner: what it executes, what it refuses to claim, and what its
/// execution numbers mean.
///
/// The suite is built around one property that is easy to lose: a stand-in can
/// produce a perfectly well-formed run - a validated manifest, a full set of
/// cases, rates with denominators - and none of it may be read as a model's
/// quality. Every test that drives the runner therefore also asserts something
/// about the gate, so a future change that quietly unlocks a claim fails here
/// rather than in a summary nobody reviewed.
@Suite("Evaluation runner")
struct EvaluationRunnerTests {
    private var profile: MappingProfile { get throws { try MappingProfile.projectArchive() } }

    /// The four slots a `validated` entry needs from the shipped Project Archive
    /// Profile: `projectname`, `completionyear` and `documentcategory` are required
    /// for `validated`, and `documenttype` is the one the reference answer states.
    private var faithfulSlots: [MetadataFieldID: String?] {
        [.projectname: "示例项目_2026", .completionyear: "2026",
         .documentcategory: "01_招标文件", .documenttype: "Tender Announcement"]
    }

    private func dataset(_ records: [GoldRecord], evaluation: Set<String>,
                         prompt: Set<String> = [], removed: [GoldSplit.Removal] = []) throws -> GoldDataset {
        let pack = try CasePack.shipped()
        let split = try GoldSplit(splitID: "split-a", datasetRevision: "1.0.0", generatedOn: "2026-11-12",
                                  casePack: .init(id: pack.id, version: pack.version),
                                  promptRecordIDs: prompt, evaluationRecordIDs: evaluation,
                                  removed: removed, notes: nil)
        return try GoldDataset(records: records, split: split, casePack: pack)
    }

    private func configuration(profile: MappingProfile, concurrency: Int = 4,
                               timeout: Duration = .seconds(5),
                               retry: EvaluationRunner.RetryPolicy = .disabled,
                               entryLimit: Int = 100, pricing: TokenPricing? = nil)
        -> EvaluationRunner.Configuration {
        EvaluationRunner.Configuration(profile: profile, model: "stand-in-model", provider: .anthropic,
                                       allowCloud: false, maximumConcurrency: concurrency,
                                       perRequestTimeout: timeout, retry: retry, entryLimit: entryLimit,
                                       bootstrapResamples: 20, bootstrapSeed: 7, pricing: pricing)
    }

    private func answerer(_ records: [GoldRecord], answers: [UUID: SubstituteAnswer] = [:],
                          fallback: SubstituteAnswer = .faithful) -> SubstituteAnswerer {
        SubstituteAnswerer(references: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) }),
                           answers: answers, fallback: fallback)
    }

    private func records(_ count: Int, cluster: String? = nil) throws -> [GoldRecord] {
        try (0..<count).map { try EvaluationFixtures.gold("g\($0)", expected: faithfulSlots, cluster: cluster) }
    }

    // MARK: - The run itself

    @Test("a stand-in run produces a validated manifest and a refused claim")
    func standInRunIsRefused() async throws {
        let records = try self.records(6)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let run = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                 configuration: configuration(profile: try profile))

        #expect(run.cases.count == 6)
        #expect(run.telemetry.sampleCount == 6)
        #expect(run.telemetry.issuedRequestCount == 6)
        #expect(run.manifest.envelope.state == .validated)
        #expect(run.cases.allSatisfy { $0.candidateState == .validated })
        #expect(run.cases.allSatisfy { $0.isAutoMapped })
        // The denominators are real; the authority is not. That combination is the
        // whole reason the gate lives in the report layer.
        #expect(run.report.slice(.coverage)?.rate.estimate == 1.0)
        #expect(!run.report.isQualityClaimAllowed)
        #expect(run.report.claimBlockers.map(\.kind).contains(.substituteAnswers))
        #expect(run.identity.isSubstitute)
        #expect(run.identity.provider == "substitute")
        #expect(run.identity.modelID == nil)
    }

    @Test("one request per record and one per batch, never one per attempt")
    func requestsAreBatchesNotAttempts() async throws {
        let records = try self.records(6, cluster: "shared-project")
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let failing = SubstituteAnswer(failure: .timeout)
        let run = try await EvaluationRunner.run(
            dataset: data,
            answerer: answerer(records, fallback: failing),
            configuration: configuration(profile: try profile, retry: .init(maximumAttempts: 3,
                                                                           initialBackoff: .milliseconds(1),
                                                                           multiplier: 1,
                                                                           maximumBackoff: .milliseconds(1))))

        // Six records in one project: one batch, one request, six samples.
        #expect(run.telemetry.requestCount == 1)
        #expect(run.telemetry.issuedRequestCount == 1)
        #expect(run.telemetry.sampleCount == 6)
        #expect(run.requests.first?.recordIDs.count == 6)
        // Three attempts each, and still one request. A retry is not a new sample.
        #expect(run.telemetry.attemptCount == 3)
        #expect(run.telemetry.retryCount == 2)
        #expect(run.requests.first?.attempts == 3)
        #expect(run.telemetry.succeededRequests == 0)
        #expect(run.telemetry.failedRequests == 1)
        #expect(run.requests.first?.outcome == MappingOutcome.timeout.rawValue)
        // Every record kept its place in the denominators even though no answer
        // arrived for any of them.
        #expect(run.cases.count == 6)
        #expect(run.cases.allSatisfy { $0.candidateState == .unknown })
        #expect(run.telemetry.failureRate == 1.0)
    }

    @Test("a batch limit splits a project without dropping a record")
    func batchLimitSplitsTheProject() async throws {
        let records = try self.records(5, cluster: "shared-project")
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let run = try await EvaluationRunner.run(
            dataset: data, answerer: answerer(records),
            configuration: configuration(profile: try profile, entryLimit: 2))

        #expect(run.telemetry.requestCount == 3)
        #expect(run.telemetry.sampleCount == 5)
        #expect(run.requests.map { $0.recordIDs.count } == [2, 2, 1])
        #expect(Set(run.requests.flatMap { $0.recordIDs }) == Set(records.map(\.recordID)))
        #expect(run.manifest.entries.count == 5)
    }

    @Test("a request that outlives its deadline is bounded by the runner")
    func deadlineBoundsAHungAnswer() async throws {
        let records = try self.records(3)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let hung = SubstituteAnswer(delay: .seconds(30))
        let clock = ContinuousClock.now
        let run = try await EvaluationRunner.run(
            dataset: data, answerer: answerer(records, fallback: hung),
            configuration: configuration(profile: try profile, timeout: .milliseconds(30)))
        let elapsed = clock.duration(to: .now)

        // Three requests at a 30 ms deadline each: bounded by the deadline, not by
        // the answerer's 30 s sleep. The bound is generous because it is only here
        // to catch a runner that stopped enforcing one.
        #expect(elapsed < .seconds(5))
        #expect(run.telemetry.timedOutAttempts == 3)
        #expect(run.telemetry.failedRequests == 3)
        #expect(run.requests.allSatisfy { $0.outcome == MappingOutcome.timeout.rawValue })
        #expect(run.cases.allSatisfy { $0.candidateState == .unknown })
        #expect(run.telemetry.sampleCount == 3)
    }

    @Test("cancellation stops the run without shrinking the sample set")
    func cancellationIsDisclosed() async throws {
        let records = try self.records(6)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let slow = SubstituteAnswer(delay: .milliseconds(80))
        let task = Task {
            try await EvaluationRunner.run(
                dataset: data, answerer: answerer(records, fallback: slow),
                configuration: configuration(profile: try profile, concurrency: 1))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let run = try await task.value

        #expect(run.telemetry.cancelled)
        // What was never issued is reported as never issued, not as a failure: the
        // distinction is the difference between "we stopped" and "the provider
        // broke". The denominator, though, is the dataset's, not the run's.
        #expect(run.telemetry.issuedRequestCount < run.telemetry.requestCount)
        #expect(run.telemetry.sampleCount == 6)
        #expect(run.cases.count == 6)
    }

    // MARK: - Concurrency

    @Test("bounded concurrency caps in-flight requests")
    func concurrencyIsBounded() async throws {
        let records = try self.records(12)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let probe = ConcurrencyProbe(delay: .milliseconds(25))
        let run = try await EvaluationRunner.run(
            dataset: data, answerer: probe,
            configuration: configuration(profile: try profile, concurrency: 3, entryLimit: 1))

        #expect(run.telemetry.maximumConcurrency == 3)
        // The runner counts in flight at spawn time, which is exact rather than
        // sampled: three slots, twelve batches, never more than three at once.
        #expect(run.telemetry.observedConcurrency == 3)
        // The answerer's own counter is the cross-check: if the cap were advisory
        // rather than structural, the two would disagree.
        let observed = await probe.maximumInFlight
        #expect(observed == 3)
        #expect((run.telemetry.throughputSamplesPerSecond ?? 0) > 0)
    }

    // MARK: - Telemetry honesty

    @Test("usage is reported or absent, and never zero")
    func usageIsNeverInvented() async throws {
        let records = try self.records(2)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))

        let silent = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                    configuration: configuration(profile: try profile))
        #expect(!silent.telemetry.usage.hasCounts)
        #expect(silent.telemetry.usage.total == nil)
        #expect(silent.telemetry.cost.amount == nil)
        #expect(silent.telemetry.cost.kind == .unavailable)
        #expect(!silent.telemetry.cost.isRealSpend)
        // A stand-in's cost is never spend, whatever the number looks like.
        #expect(silent.telemetry.latency.p50Milliseconds == nil)

        let reported = SubstituteAnswer(usage: .simulated(input: 1_000, output: 500, cacheRead: 100))
        let measured = try await EvaluationRunner.run(
            dataset: data, answerer: answerer(records, fallback: reported),
            configuration: configuration(profile: try profile))
        #expect(measured.telemetry.usage.kind == .simulated)
        #expect(measured.telemetry.usage.input == 2_000)
        #expect(measured.telemetry.usage.output == 1_000)
        #expect(measured.telemetry.usage.cacheRead == 200)
        // 1000 + 500 + 100 per request, two requests.
        #expect(measured.telemetry.usage.total == 3_200)
        #expect(!measured.telemetry.cost.isRealSpend)
    }

    @Test("a price is stated with its version and the projection is not a spend")
    func costCarriesItsProvenance() async throws {
        let records = try self.records(1)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let pricing = TokenPricing(
            id: "test-pricing-1", provider: "anthropic", modelID: "stand-in-model", currency: "USD",
            effectiveOn: "2026-11-12", source: "synthetic test price set",
            inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheCreationPerMillion: 3.75)
        let reported = SubstituteAnswer(usage: .simulated(input: 1_000_000, output: 0))
        let run = try await EvaluationRunner.run(
            dataset: data, answerer: answerer(records, fallback: reported),
            configuration: configuration(profile: try profile, pricing: pricing))

        #expect(run.telemetry.cost.pricingID == "test-pricing-1")
        #expect(run.telemetry.cost.currency == "USD")
        #expect(run.telemetry.cost.kind == .simulated)
        #expect(run.telemetry.cost.amount == 3.0)
        #expect(!run.telemetry.cost.isRealSpend)
        // PLAN §8.2's `1000/N × 实测费用`, with the assumption stated beside it.
        #expect(run.telemetry.cost.thousandSampleExtrapolation?.amount == 3_000)
        #expect(run.telemetry.cost.thousandSampleExtrapolation?.sampleCount == 1)
        #expect(run.telemetry.cost.thousandSampleExtrapolation?.basis == .simulated)
        #expect(run.telemetry.cost.thousandSampleExtrapolation?.assumption.contains("1 samples") == true)
    }

    @Test("a non-streaming answer reports no first-token latency")
    func firstTokenIsAbsentUnlessObserved() async throws {
        let records = try self.records(2)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))

        let plain = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                   configuration: configuration(profile: try profile))
        #expect(!plain.telemetry.firstToken.isObservable)
        #expect(plain.telemetry.firstToken.p50Milliseconds == nil)
        #expect(plain.telemetry.firstToken.sampleCount == 0)

        // The same run with a reported first token: the column exists, and it is
        // not the total response time.
        let streaming = SubstituteAnswer(firstTokenMilliseconds: 40, reportedLatencyMilliseconds: 900)
        let observed = try await EvaluationRunner.run(
            dataset: data, answerer: answerer(records, fallback: streaming),
            configuration: configuration(profile: try profile))
        #expect(observed.telemetry.firstToken.isObservable)
        #expect(observed.telemetry.firstToken.p50Milliseconds == 40)
        #expect(observed.telemetry.firstToken.p95Milliseconds == 40)
        #expect(observed.telemetry.firstToken.sampleCount == 2)
        // And the reported total is kept apart from it.
        #expect(observed.telemetry.latency.p50Milliseconds == 900)
    }

    @Test("latency percentiles are absent when no request reported one")
    func latencyNeedsAnObservation() async throws {
        let records = try self.records(4)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let run = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                 configuration: configuration(profile: try profile))
        #expect(run.telemetry.latency.sampleCount == 0)
        #expect(run.telemetry.latency.p50Milliseconds == nil)
        #expect(run.telemetry.latency.maximumMilliseconds == nil)
    }

    @Test("a request digest is reproducible for the same dataset")
    func runIsReproducible() async throws {
        let records = try self.records(3)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let first = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                   configuration: configuration(profile: try profile))
        let second = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                    configuration: configuration(profile: try profile))

        #expect(first.runID == second.runID)
        #expect(first.manifest.envelope.manifestID == second.manifest.envelope.manifestID)
        #expect(first.manifest.envelope.inputDigest == second.manifest.envelope.inputDigest)
        #expect(first.manifest.entries.map(\.sourceID) == second.manifest.entries.map(\.sourceID))
        // A different configuration is a different run, even on the same dataset.
        let other = try await EvaluationRunner.run(
            dataset: data, answerer: answerer(records),
            configuration: configuration(profile: try profile, concurrency: 2))
        #expect(other.runID != first.runID)
    }

    // MARK: - Boundary and isolation

    @Test("the boundary names what the run did not score")
    func boundaryDisclosesExclusions() async throws {
        let countable = try self.records(3)
        let promptSide = try EvaluationFixtures.gold("p0", expected: faithfulSlots, cluster: "cluster-p0",
                                                     usage: .fewshot)
        let withdrawn = try EvaluationFixtures.gold("r0", expected: faithfulSlots, cluster: "cluster-r0")
        let data = try dataset(countable + [promptSide, withdrawn],
                               evaluation: Set(countable.map(\.recordID)),
                               prompt: ["p0"],
                               removed: [.init(recordID: "r0", reason: .nearDuplicate,
                                               counterpartyRecordID: nil)])
        let run = try await EvaluationRunner.run(dataset: data, answerer: answerer(countable),
                                                 configuration: configuration(profile: try profile))

        #expect(run.boundary.datasetRecords == 5)
        #expect(run.boundary.countable == 3)
        #expect(run.boundary.evaluated == 3)
        #expect(run.boundary.promptSideRecords == 1)
        #expect(run.boundary.withdrawnRecords == 1)
        #expect(run.cases.count == 3)
        #expect(run.cases.allSatisfy { $0.recordID.hasPrefix("g") })
        // Prompt-side and withdrawn material never reached the answerer: a leak
        // would show up as a case that the dataset itself excludes.
        #expect(Set(run.cases.map(\.recordID)).isDisjoint(with: ["p0", "r0"]))
    }

    @Test("a cluster naming two projects cannot be described honestly")
    func clusterWithTwoProjectsIsRefused() async throws {
        let first = try EvaluationFixtures.gold("a", expected: faithfulSlots, cluster: "shared",
                                                project: "cl-pa-001")
        let second = try EvaluationFixtures.gold("b", expected: faithfulSlots, cluster: "shared",
                                                 project: "cl-pa-002")
        let data = try dataset([first, second], evaluation: ["a", "b"])
        var caught: FormaError?
        do {
            _ = try await EvaluationRunner.run(dataset: data, answerer: answerer([first, second]),
                                               configuration: configuration(profile: try profile))
        } catch let error as FormaError {
            caught = error
        }
        #expect(caught == .incompatible)
    }

    @Test("an answer naming a reference the run never issued is refused")
    func unknownReferenceIsRefused() async throws {
        let records = try self.records(2)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let run = try await EvaluationRunner.run(dataset: data, answerer: InventingAnswerer(),
                                                 configuration: configuration(profile: try profile))

        #expect(run.refusedReferences == 2)
        // The invented reference creates nothing: every record stays unanswered
        // rather than acquiring a mapping nobody issued.
        #expect(run.manifest.entries.count == 2)
        #expect(run.manifest.entries.allSatisfy { $0.state == .unknown })
        #expect(run.cases.allSatisfy { $0.candidateState == .unknown })
    }

    // MARK: - Export

    @Test("the exported artifact carries the refusal and no source paths")
    func exportIsRedactedAndSelfDescribing() async throws {
        let records = try self.records(2)
        let data = try dataset(records, evaluation: Set(records.map(\.recordID)))
        let run = try await EvaluationRunner.run(dataset: data, answerer: answerer(records),
                                                 configuration: configuration(profile: try profile))
        let bytes = try run.export()
        let text = String(decoding: bytes, encoding: .utf8)

        // The manifest's own paths are exactly what a shareable report may not carry.
        #expect(!text.contains("synthetic/"))
        #expect(artifact.runID == run.runID)
        #expect(artifact.identity.isSubstitute)
        #expect(artifact.report.claimBlockers.contains { $0.kind == .substituteAnswers })
        #expect(!artifact.report.isQualityClaimAllowed)
        #expect(artifact.boundary.evaluated == 2)
        #expect(artifact.telemetry.sampleCount == 2)
        #expect(artifact.schemaVersion == "1.0")
    }
}

/// A stand-in that reports only how many calls it had in flight at once.
///
/// The runner's own `observedConcurrency` is exact, so this exists to check it
/// against a second, independent count: if the cap ever became advisory, the two
/// would disagree.
private actor ConcurrencyProbe: MappingAnswering {
    private let delay: Duration
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    init(delay: Duration) { self.delay = delay }

    func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                redaction: RedactionPlan) async -> MappingAttempt {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        try? await Task.sleep(for: delay)
        inFlight -= 1
        return MappingAttempt(proposal: MappingProposal(batchID: batch.id, entries: []),
                              latencyMilliseconds: 1, requests: 1)
    }
}

/// An answer that cites a reference the run never issued.
private struct InventingAnswerer: MappingAnswering {
    func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                redaction: RedactionPlan) async -> MappingAttempt {
        let invented = ProposalEntry(
            entryRef: "e999", projectAssociation: nil, documentCategory: nil, documentType: nil,
            metadata: .allUnknown, evidence: [], unknownFields: [], conflicts: [], confidence: .low,
            reasoning: "a reference the run never issued")
        return MappingAttempt(proposal: MappingProposal(batchID: batch.id, entries: [invented]), requests: 1)
    }
}