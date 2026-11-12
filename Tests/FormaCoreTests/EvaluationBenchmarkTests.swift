import Foundation
import Testing

@testable import FormaCore

/// The 2c correctness gate: the synthetic fixture, the stage breakdown and the
/// benchmark result are deterministic and honest. Performance numbers are not
/// asserted here - a hosted runner's wall clock is not a contract.
@Suite("Evaluation benchmark")
struct EvaluationBenchmarkTests {
    private func spec(_ records: Int = 100, clusters: Int = 10, seed: UInt64 = 7) -> EvaluationBenchmarkFixture.Spec {
        EvaluationBenchmarkFixture.Spec(recordCount: records, clusterCount: clusters, seed: seed)
    }

    private func scenario(_ records: Int = 100, concurrency: Int = 4, entryLimit: Int = 25,
                          fault: EvaluationBenchmark.FaultMode = .success, rate: Double = 0,
                          latency: Int = 2, retries: Int = 1,
                          cancelAfter: Int? = nil, label: String = "test") -> EvaluationBenchmark.Scenario {
        EvaluationBenchmark.Scenario(label: label, recordCount: records, clusterCount: 10,
                                     entryLimit: entryLimit, maximumConcurrency: concurrency,
                                     faultMode: fault, faultRate: rate,
                                     simulatedLatencyMilliseconds: latency, bootstrapResamples: 20,
                                     bootstrapSeed: 7, fixtureSeed: 7, promptRecordCount: 0,
                                     removedRecordCount: 0, perRequestTimeoutMilliseconds: 5_000,
                                     retryMaximumAttempts: retries, cancelAfterMilliseconds: cancelAfter)
    }

    // MARK: - Fixture

    @Test("a fixture is reproducible and its identity changes with the seed")
    func fixtureReproducibility() throws {
        let first = try EvaluationBenchmarkFixture.build(spec())
        let second = try EvaluationBenchmarkFixture.build(spec())
        let other = try EvaluationBenchmarkFixture.build(spec(seed: 8))

        #expect(first.fixtureID == second.fixtureID)
        #expect(first.dataset.records.map(\.recordID) == second.dataset.records.map(\.recordID))
        #expect(first.dataset.split == second.dataset.split)
        #expect(first.dataset.report() == second.dataset.report())
        #expect(first.countableRecords == second.countableRecords)
        #expect(first.dataset.records.map(\.source.projectClusterKey)
                    == second.dataset.records.map(\.source.projectClusterKey))
        // The seed must actually change the logical input, not just the label.
        #expect(first.fixtureID != other.fixtureID)
        #expect(first.dataset.records.map { $0.expected.metadata[.documenttype] }
                    != other.dataset.records.map { $0.expected.metadata[.documenttype] })
    }

    @Test("a 10,000-record fixture keeps every identity unique and countable")
    func tenThousandIdentities() throws {
        let fixture = try EvaluationBenchmarkFixture.build(spec(10_000, clusters: 100))
        let records = fixture.dataset.records
        #expect(records.count == 10_000)
        #expect(Set(records.map(\.recordID)).count == 10_000)
        #expect(Set(records.map { EvaluationFixture.sourceID(for: $0.recordID) }).count == 10_000)
        #expect(Set(records.map(\.source.projectClusterKey)).count == 100)
        // No synthetic family collides with the shipped CasePack, so the leak
        // check must not quietly empty the denominator.
        #expect(fixture.countableRecords == 10_000)
        #expect(fixture.dataset.report().unaccountedRecords.isEmpty)
    }

    @Test("the boundary lists stay out of the denominator")
    func boundaryListsAreNotCountable() throws {
        let fixture = try EvaluationBenchmarkFixture.build(
            EvaluationBenchmarkFixture.Spec(recordCount: 40, clusterCount: 4,
                                            promptRecordCount: 5, removedRecordCount: 3, seed: 7))
        #expect(fixture.dataset.records.count == 48)
        #expect(fixture.countableRecords == 40)
        #expect(fixture.dataset.split.promptRecordIDs.count == 5)
        #expect(fixture.dataset.split.removed.count == 3)
        #expect(fixture.dataset.report().unaccountedRecords.isEmpty)
    }

    // MARK: - Accounting invariants

    @Test("samples, requests and attempts obey the runner's state machine")
    func sampleRequestAttemptInvariant() async throws {
        let result = try await EvaluationBenchmark.execute(scenario())
        #expect(result.violations().isEmpty)
        #expect(result.fixture.countableRecords == result.telemetry.sampleCount)
        #expect(result.telemetry.requestCount >= result.telemetry.issuedRequestCount)
        #expect(result.telemetry.attemptCount >= result.telemetry.issuedRequestCount)
        #expect(result.telemetry.observedConcurrency <= result.telemetry.maximumConcurrency)
        #expect(result.telemetry.retryCount == result.telemetry.attemptCount
                    - result.telemetry.issuedRequestCount)
    }

    @Test("a smaller batch limit splits requests without losing a record")
    func batchSplittingConservation() async throws {
        // One cluster: 100 records, so the engine makes 4 batches at 25 and 1 at 100.
        let many = try await EvaluationBenchmark.execute(EvaluationBenchmark.Scenario(
            label: "split", recordCount: 100, clusterCount: 1, entryLimit: 25,
            maximumConcurrency: 4, bootstrapResamples: 20, bootstrapSeed: 7, fixtureSeed: 7))
        let one = try await EvaluationBenchmark.execute(EvaluationBenchmark.Scenario(
            label: "unsplit", recordCount: 100, clusterCount: 1, entryLimit: 100,
            maximumConcurrency: 4, bootstrapResamples: 20, bootstrapSeed: 7, fixtureSeed: 7))

        #expect(many.telemetry.sampleCount == one.telemetry.sampleCount)
        #expect(many.telemetry.requestCount > one.telemetry.requestCount)
        #expect(many.telemetry.issuedRequestCount == many.telemetry.requestCount)
        // 2b's run identity names the batch limit; a different plan is a
        // different run, but the same dataset's samples are still all scored.
        #expect(many.runID != one.runID)
        #expect(many.violations().isEmpty)
        #expect(one.violations().isEmpty)
    }

    @Test("configured concurrency is a ceiling, not an estimate")
    func concurrencyBound() async throws {
        for limit in [1, 2, 4, 8] {
            let result = try await EvaluationBenchmark.execute(
                scenario(concurrency: limit, label: "c\(limit)"))
            #expect(result.telemetry.maximumConcurrency == limit)
            #expect(result.telemetry.observedConcurrency <= limit)
            #expect(result.telemetry.issuedRequestCount == result.telemetry.requestCount)
            #expect(result.violations().isEmpty)
        }
    }

    @Test("retries add attempts, never samples or requests")
    func retryAccounting() async throws {
        let result = try await EvaluationBenchmark.execute(
            scenario(fault: .retry, rate: 1, retries: 3, label: "retry"))
        let t = result.telemetry
        #expect(t.sampleCount == result.fixture.countableRecords)
        #expect(t.retryCount == t.issuedRequestCount * 2)
        #expect(t.attemptCount == t.issuedRequestCount * 3)
        #expect(t.failedRequests == t.issuedRequestCount)
        #expect(result.violations().isEmpty)
    }

    @Test("cancelled and not-issued requests are separate from failures")
    func cancellationAccounting() async throws {
        let notIssued = try await EvaluationBenchmark.execute(
            scenario(fault: .notIssued, latency: 20, cancelAfter: 0, label: "not-issued"))
        #expect(notIssued.telemetry.cancelled)
        #expect(notIssued.telemetry.requestCount > 0)
        #expect(notIssued.telemetry.issuedRequestCount == 0)
        #expect(notIssued.telemetry.failedRequests == 0)
        #expect(notIssued.telemetry.sampleCount == notIssued.fixture.countableRecords)
        #expect(notIssued.violations().isEmpty)

        let cancelled = try await EvaluationBenchmark.execute(
            scenario(fault: .cancelled, latency: 20, cancelAfter: 5, label: "cancelled"))
        #expect(cancelled.telemetry.sampleCount == cancelled.fixture.countableRecords)
        #expect(cancelled.telemetry.issuedRequestCount <= cancelled.telemetry.requestCount)
        #expect(cancelled.telemetry.attemptCount >= cancelled.telemetry.issuedRequestCount)
        #expect(cancelled.violations().isEmpty)
    }

    @Test("a missing observation is unavailable, never a zero")
    func missingObservationSemantics() async throws {
        let result = try await EvaluationBenchmark.execute(scenario(latency: 0, label: "no-latency"))
        #expect(!result.telemetry.usage.hasCounts)
        #expect(result.telemetry.usage.total == nil)
        #expect(result.telemetry.latency.kind == .unavailable)
        #expect(result.telemetry.latency.p50Milliseconds == nil)
        #expect(!result.telemetry.firstToken.isObservable)
        #expect(result.telemetry.cost.amount == nil)
        #expect(result.violations().isEmpty)

        let notRun = EvaluationStageMeasurement.notRun(.reportAndMetrics, reason: "test")
        #expect(!notRun.isObserved)
        #expect(notRun.wallClockMilliseconds == nil)
        #expect(notRun.kind == .unavailable)
        #expect(notRun.unavailableReason == "test")
    }

    // MARK: - Stages, export and identity

    @Test("every stage is timed and the total is never a sum of stages")
    func performanceStageCoverage() async throws {
        let result = try await EvaluationBenchmark.execute(scenario(label: "stages"))
        #expect(result.stageTimings.stages.count == EvaluationStage.allCases.count)
        for stage in EvaluationStage.allCases {
            let measurement = result.stageTimings.measurement(for: stage)
            #expect(measurement != nil)
            #expect(measurement?.isObserved == true)
            #expect(measurement?.kind == .measured)
        }
        let sum = try #require(result.stageTimings.sumOfStageMilliseconds)
        #expect(sum <= result.stageTimings.totalWallClockMilliseconds)
        #expect(result.stageTimings.unaccountedMilliseconds != nil)
        #expect(result.telemetry.wallClockMilliseconds <= result.stageTimings.totalWallClockMilliseconds)
        #expect(result.violations().isEmpty)
    }

    @Test("the shareable result has a schema version and no source paths")
    func redactedExportAndSchema() async throws {
        let result = try await EvaluationBenchmark.execute(scenario(label: "export"))
        #expect(result.schemaVersion == EvaluationBenchmark.schemaVersion)
        let data = try FormaJSON.encode(result, pretty: true)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("synthetic/"))
        #expect(!text.contains("redacted_relative_path"))
        #expect(!text.contains("redacted_filename"))
        #expect(!text.contains("credential"))
        #expect(text.contains("benchmark_schema_version"))
        #expect(text.contains("stage_timings"))
        let decoded = try FormaJSON.decode(EvaluationBenchmark.Result.self, from: data)
        #expect(decoded.benchmarkID == result.benchmarkID)
        #expect(decoded.measurementID == result.measurementID)
        #expect(decoded.violations().isEmpty)
    }

    @Test("one logical benchmark, two distinct measurements, one run identity")
    func benchmarkIdentityVersusMeasurement() async throws {
        let cell = scenario(label: "repeat")
        let first = try await EvaluationBenchmark.execute(cell)
        let second = try await EvaluationBenchmark.execute(cell)
        #expect(first.benchmarkID == second.benchmarkID)
        #expect(first.measurementID != second.measurementID)
        #expect(first.fixture.fixtureID == second.fixture.fixtureID)
        // 2b's determinism contract is untouched: same dataset + same config.
        #expect(first.runID == second.runID)
        #expect(first.violations().isEmpty)
        #expect(second.violations().isEmpty)
    }

    @Test("an offline benchmark never reaches a provider or claims model quality")
    func noProviderAccess() async throws {
        let result = try await EvaluationBenchmark.execute(scenario(label: "offline"))
        #expect(result.identity.isSubstitute)
        #expect(result.identity.provider == "substitute")
        #expect(result.identity.modelID == nil)
        #expect(result.configuration.allowCloud == false)
        #expect(result.configuration.pricingID == nil)
        #expect(!result.report.isQualityClaimAllowed)
        #expect(result.report.claimBlockerKinds.contains(EvaluationReport.Blocker.substituteAnswers.rawValue))
        #expect(result.telemetry.usage.kind != .measured)
        #expect(result.telemetry.latency.kind != .measured)
        #expect(!result.telemetry.firstToken.isObservable)
        #expect(result.limitations.contains { $0.contains("no provider") })
    }
}