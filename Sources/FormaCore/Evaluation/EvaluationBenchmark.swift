import Darwin
import Foundation

// One benchmark execution, from a deterministic fixture to a shareable result.
//
// What this file owns: the scenario (the matrix cell), the fault roll, the
// cancellation gate, the memory and environment observations, and the result
// document. What it does not own: batching (MappingEngine), validation
// (ManifestValidator), judgement (CaseJudgement), metrics (EvaluationReport), or
// the run identity (EvaluationRunner). Re-deriving any of those here would make
// a benchmark green while the production path was broken, which is the one
// failure mode a benchmark must never have.
//
// The three things the numbers are not allowed to claim are stated in
// `limitations` on every result: this is not a file scan, not a provider
// measurement, and not a quality conclusion. PLAN §8.2 asks for 合成压力数据单列,
// 不冒充真实实测; that separation is a field, not a promise in a README.

public enum EvaluationBenchmark {
    /// Bumped when a JSON field changes meaning or when a field is added.
    public static let schemaVersion = "1.0"

    /// What the stand-in does to a request. All of these are *injected outcomes*,
    /// not provider behaviour: a `timeout` here is a failed attempt the harness
    /// was told to produce, and the runner's own deadline race remains covered by
    /// `EvaluationRunnerTests.deadlineBoundsAHungAnswer`.
    ///
    /// `syntheticSkip` is deliberately absent. Skipping a record is an Import
    /// engine decision (`SKIP_VERIFIED`), and adding a skip seam to the runner
    /// would change the denominators PLAN §8.2 fixes. "Not issued" is reachable
    /// here as cancellation before a batch was sent, which is a scheduling fact,
    /// not an Import state.
    public enum FaultMode: String, Codable, Sendable, CaseIterable {
        case success
        /// A retryable failure, retried to the configured attempt ceiling.
        case retry
        /// A request-level timeout failure.
        case timeout
        /// A permanent, non-retryable unavailable answer.
        case permanentUnavailable = "permanent_unavailable"
        /// A slow success, so the concurrency sweep has something to overlap.
        case delayed
        /// A success with withheld slots: partial completion inside a request.
        case partial
        /// Cancelled while requests are in flight.
        case cancelled
        /// Cancelled before the first request was issued.
        case notIssued = "not_issued"
    }

    /// One matrix cell. Every field that can change the logical question is part
    /// of `material`, so the same cell on two machines has the same
    /// `benchmarkID`; every field that describes *this* execution (timings,
    /// environment, memory, clocks) is not.
    public struct Scenario: Codable, Sendable, Equatable {
        public let label: String
        public let recordCount: Int
        public let clusterCount: Int
        public let entryLimit: Int
        public let maximumConcurrency: Int
        public let faultMode: FaultMode
        /// Fraction of requests the fault applies to, rolled deterministically.
        public let faultRate: Double
        /// Simulated answer latency, in milliseconds. A stand-in's latency is a
        /// `Task.sleep`, so it is `simulated`, never a provider measurement.
        public let simulatedLatencyMilliseconds: Int
        public let bootstrapResamples: Int
        public let bootstrapSeed: UInt64
        public let fixtureSeed: UInt64
        public let promptRecordCount: Int
        public let removedRecordCount: Int
        public let perRequestTimeoutMilliseconds: Int
        public let retryMaximumAttempts: Int
        /// Nil for an uninterrupted run; 0 cancels before the first request.
        public let cancelAfterMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case label, recordCount = "record_count", clusterCount = "cluster_count"
            case entryLimit = "entry_limit", maximumConcurrency = "maximum_concurrency"
            case faultMode = "fault_mode", faultRate = "fault_rate"
            case simulatedLatencyMilliseconds = "simulated_latency_milliseconds"
            case bootstrapResamples = "bootstrap_resamples", bootstrapSeed = "bootstrap_seed"
            case fixtureSeed = "fixture_seed", promptRecordCount = "prompt_record_count"
            case removedRecordCount = "removed_record_count"
            case perRequestTimeoutMilliseconds = "per_request_timeout_milliseconds"
            case retryMaximumAttempts = "retry_maximum_attempts"
            case cancelAfterMilliseconds = "cancel_after_milliseconds"
        }

        public init(label: String = "smoke", recordCount: Int = 100, clusterCount: Int = 10,
                    entryLimit: Int = 25, maximumConcurrency: Int = 4, faultMode: FaultMode = .success,
                    faultRate: Double = 0, simulatedLatencyMilliseconds: Int = 2,
                    bootstrapResamples: Int = 20, bootstrapSeed: UInt64 = 7,
                    fixtureSeed: UInt64 = 0x9E37_79B9_7F4A_7C15,
                    promptRecordCount: Int = 0, removedRecordCount: Int = 0,
                    perRequestTimeoutMilliseconds: Int = 5_000, retryMaximumAttempts: Int = 1,
                    cancelAfterMilliseconds: Int? = nil) {
            self.label = label
            self.recordCount = max(0, recordCount)
            self.clusterCount = max(1, clusterCount)
            self.entryLimit = max(1, entryLimit)
            self.maximumConcurrency = max(1, maximumConcurrency)
            self.faultMode = faultMode
            self.faultRate = min(max(0, faultRate), 1)
            self.simulatedLatencyMilliseconds = max(0, simulatedLatencyMilliseconds)
            self.bootstrapResamples = max(1, bootstrapResamples)
            self.bootstrapSeed = bootstrapSeed
            self.fixtureSeed = fixtureSeed
            self.promptRecordCount = max(0, promptRecordCount)
            self.removedRecordCount = max(0, removedRecordCount)
            self.perRequestTimeoutMilliseconds = max(1, perRequestTimeoutMilliseconds)
            self.retryMaximumAttempts = max(1, retryMaximumAttempts)
            self.cancelAfterMilliseconds = cancelAfterMilliseconds.map { max(0, $0) }
        }

        public var material: String {
            "forma.benchmark.scenario.v1|\(EvaluationBenchmark.schemaVersion)|\(label)|\(recordCount)"
                + "|\(clusterCount)|\(entryLimit)|\(maximumConcurrency)|\(faultMode.rawValue)|\(faultRate)"
                + "|\(simulatedLatencyMilliseconds)|\(bootstrapResamples)|\(bootstrapSeed)|\(fixtureSeed)"
                + "|\(promptRecordCount)|\(removedRecordCount)|\(perRequestTimeoutMilliseconds)"
                + "|\(retryMaximumAttempts)|\(cancelAfterMilliseconds.map(String.init) ?? "none")"
        }

        /// A light cell for a PR; the 10k cells are built by the workflow's CLI
        /// flags rather than by a preset, so the matrix is visible in one place.
        public static let smoke = Scenario()
    }

    /// The fixture a scenario ran against, as identity rather than content.
    public struct FixtureIdentity: Codable, Sendable, Equatable {
        public let fixtureID: String
        public let fixtureSeed: UInt64
        public let fixtureVersion: String
        public let recordCount: Int
        public let clusterCount: Int
        public let totalRecordCount: Int
        public let countableRecords: Int
        public let promptRecordCount: Int
        public let removedRecordCount: Int

        enum CodingKeys: String, CodingKey {
            case fixtureID = "fixture_id", fixtureSeed = "fixture_seed", fixtureVersion = "fixture_version"
            case recordCount = "record_count", clusterCount = "cluster_count"
            case totalRecordCount = "total_record_count", countableRecords = "countable_records"
            case promptRecordCount = "prompt_record_count", removedRecordCount = "removed_record_count"
        }
    }

    /// The run's configuration, stated as fields so a result can be re-run.
    public struct ConfigurationSummary: Codable, Sendable, Equatable {
        public let profileID: String
        public let profileVersion: String
        public let provider: String
        public let model: String
        public let allowCloud: Bool
        public let maximumConcurrency: Int
        public let entryLimit: Int
        public let perRequestTimeoutMilliseconds: Int
        public let retryMaximumAttempts: Int
        public let bootstrapResamples: Int
        public let bootstrapSeed: UInt64
        /// Nil: FormaCore ships no prices, and an unpriced cost is not a spend.
        public let pricingID: String?

        enum CodingKeys: String, CodingKey {
            case profileID = "profile_id", profileVersion = "profile_version", provider, model
            case allowCloud = "allow_cloud", maximumConcurrency = "maximum_concurrency"
            case entryLimit = "entry_limit", perRequestTimeoutMilliseconds = "per_request_timeout_milliseconds"
            case retryMaximumAttempts = "retry_maximum_attempts"
            case bootstrapResamples = "bootstrap_resamples", bootstrapSeed = "bootstrap_seed"
            case pricingID = "pricing_id"
        }
    }

    /// Peak RSS, or an explicit unavailable reason - never a zero that reads as
    /// "measured nothing".
    public struct BenchmarkMemory: Codable, Sendable, Equatable {
        public let peakResidentBytes: Int?
        public let kind: MeasurementKind
        public let unavailableReason: String?
        /// What the peak covers. `ru_maxrss` is a process-lifetime maximum, so a
        /// process that ran several scenarios cannot attribute it to one.
        public let scope: String

        enum CodingKeys: String, CodingKey {
            case peakResidentBytes = "peak_resident_bytes", kind
            case unavailableReason = "unavailable_reason", scope
        }
    }

    /// The machine, OS and toolchain. Host name and user name are deliberately
    /// absent: they are identifying facts, and a shareable artifact has no need
    /// for them. The workflow pins the toolchain in its own YAML and log.
    public struct BenchmarkEnvironment: Codable, Sendable, Equatable {
        public let runner: String
        public let osVersion: String
        public let machineModel: String?
        public let physicalMemoryBytes: Int?
        public let processorCount: Int
        public let swiftVersion: String?
        public let xcodeVersion: String?

        enum CodingKeys: String, CodingKey {
            case runner, osVersion = "os_version", machineModel = "machine_model"
            case physicalMemoryBytes = "physical_memory_bytes", processorCount = "processor_count"
            case swiftVersion = "swift_version", xcodeVersion = "xcode_version"
        }

        public init(runner: String = "local", osVersion: String = "unknown", machineModel: String? = nil,
                    physicalMemoryBytes: Int? = nil, processorCount: Int = 0, swiftVersion: String? = nil,
                    xcodeVersion: String? = nil) {
            self.runner = runner
            self.osVersion = osVersion
            self.machineModel = machineModel
            self.physicalMemoryBytes = physicalMemoryBytes
            self.processorCount = processorCount
            self.swiftVersion = swiftVersion
            self.xcodeVersion = xcodeVersion
        }

        public static func current(runner: String = "local", swiftVersion: String? = nil,
                                   xcodeVersion: String? = nil) -> BenchmarkEnvironment {
            let info = ProcessInfo.processInfo
            return BenchmarkEnvironment(
                runner: runner, osVersion: info.operatingSystemVersionString,
                machineModel: machineModel(),
                physicalMemoryBytes: info.physicalMemory > 0 ? Int(info.physicalMemory) : nil,
                processorCount: info.processorCount, swiftVersion: swiftVersion, xcodeVersion: xcodeVersion)
        }

        private static func machineModel() -> String? {
            var size = 0
            guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
            return buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
        }
    }

    /// The gate that makes a quality claim refuse itself in the benchmark too.
    public struct ReportSummary: Codable, Sendable, Equatable {
        public let cases: Int
        public let clusters: Int
        public let isQualityClaimAllowed: Bool
        public let claimBlockerKinds: [String]
        public let countableRecords: Int
        public let pendingAdjudication: Int
        public let unaccountedRecords: Int

        enum CodingKeys: String, CodingKey {
            case cases, clusters, isQualityClaimAllowed = "is_quality_claim_allowed"
            case claimBlockerKinds = "claim_blocker_kinds", countableRecords = "countable_records"
            case pendingAdjudication = "pending_adjudication", unaccountedRecords = "unaccounted_records"
        }
    }

    /// One measured execution of one logical benchmark cell.
    public struct Result: Codable, Sendable, Equatable {
        public let schemaVersion: String
        /// Reproducible across machines: scenario + fixture, and no measured value.
        public let benchmarkID: String
        /// Unique to this execution. Two results may share a `benchmarkID` and
        /// still be two different measurements of it; they never share this.
        public let measurementID: String
        public let executedAt: Date
        public let fixture: FixtureIdentity
        public let scenario: Scenario
        public let configuration: ConfigurationSummary
        public let stageTimings: EvaluationStageTimings
        public let telemetry: EvaluationTelemetry
        public let runID: String
        public let identity: EvaluationRunIdentity
        public let boundary: EvaluationBoundary
        public let report: ReportSummary
        public let memory: BenchmarkMemory
        public let environment: BenchmarkEnvironment
        public let limitations: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "benchmark_schema_version", benchmarkID = "benchmark_id"
            case measurementID = "measurement_id", executedAt = "executed_at", fixture, scenario
            case configuration, stageTimings = "stage_timings", telemetry = "execution_telemetry"
            case runID = "run_id", identity, boundary, report, memory = "peak_memory"
            case environment, limitations
        }

        /// Contract checks a benchmark result must pass, as data rather than an
        /// exception: CI can print all of them in one run instead of stopping at
        /// the first. These are state-machine invariants, not performance
        /// thresholds - a slow hosted runner never fails here.
        public func violations() -> [String] {
            var found: [String] = []
            func check(_ condition: Bool, _ message: String) { if !condition { found.append(message) } }

            let t = telemetry
            check(fixture.countableRecords == t.sampleCount,
                  "sampleCount \(t.sampleCount) != countableRecords \(fixture.countableRecords)")
            check(t.requestCount >= t.issuedRequestCount,
                  "requestCount \(t.requestCount) < issuedRequestCount \(t.issuedRequestCount)")
            check(t.attemptCount >= t.issuedRequestCount,
                  "attemptCount \(t.attemptCount) < issuedRequestCount \(t.issuedRequestCount)")
            check(t.observedConcurrency <= t.maximumConcurrency,
                  "observedConcurrency \(t.observedConcurrency) > maximumConcurrency \(t.maximumConcurrency)")
            check(t.succeededRequests + t.failedRequests == t.issuedRequestCount,
                  "succeededRequests + failedRequests != issuedRequestCount")
            check(t.retryCount == t.attemptCount - t.issuedRequestCount,
                  "retryCount \(t.retryCount) != attemptCount - issuedRequestCount")
            check(!identity.isSubstitute || !report.isQualityClaimAllowed,
                  "a stand-in run published a quality claim")
            check(!identity.isSubstitute || t.usage.kind != .measured,
                  "a stand-in run claimed measured provider usage")
            check(!identity.isSubstitute || t.latency.kind != .measured,
                  "a stand-in run claimed measured provider latency")
            check(!identity.isSubstitute || !t.firstToken.isObservable,
                  "a non-streaming stand-in reported time to first token")
            check(configuration.allowCloud == false, "allowCloud was enabled in an offline benchmark")
            check(configuration.pricingID == nil, "an offline benchmark supplied a price list")
            check(memory.kind != .unavailable || memory.peakResidentBytes == nil,
                  "an unavailable memory observation published a byte count")
            for stage in EvaluationStage.allCases {
                guard let measurement = stageTimings.measurement(for: stage) else {
                    found.append("stage \(stage.rawValue) has no row")
                    continue
                }
                check(measurement.isObserved, "stage \(stage.rawValue) is marked unavailable")
            }
            return found
        }
    }

    /// What every result says about itself, regardless of the scenario.
    public static let limitations = [
        "synthetic fixture: no file was read or scanned; this is not M9's real 10,000-file scan",
        "deterministic stand-in: no provider was contacted; token usage, cost and model latency are simulated",
        "wall clock is this process's monotonic clock on a possibly shared runner; absolute durations are not a PR gate",
        "peak resident memory is a process-lifetime maximum (ru_maxrss), not an isolated per-scenario allocation",
        "no price list was supplied: cost is unpriced and never a real spend",
        "injected failures, retries and delays are harness outcomes, not provider behaviour",
    ]

    // MARK: - Execution

    /// Execute one cell and return the result. Throws only when the fixture or the
    /// run cannot be described honestly; an injected failure is a recorded
    /// outcome inside the result, not an error.
    public static func execute(_ scenario: Scenario, environment: BenchmarkEnvironment = .current(),
                               memoryIsolated: Bool = true) async throws -> Result {
        let executedAt = Date()
        let measuredStart = EvaluationStageTimings.now()

        let spec = EvaluationBenchmarkFixture.Spec(
            recordCount: scenario.recordCount, clusterCount: scenario.clusterCount,
            promptRecordCount: scenario.promptRecordCount, removedRecordCount: scenario.removedRecordCount,
            seed: scenario.fixtureSeed)
        let fixture = try EvaluationBenchmarkFixture.build(spec)

        let profile = try MappingProfile.projectArchive()
        let configuration = EvaluationRunner.Configuration(
            profile: profile, model: "stand-in-model", provider: .anthropic, allowCloud: false,
            maximumConcurrency: scenario.maximumConcurrency,
            perRequestTimeout: .milliseconds(scenario.perRequestTimeoutMilliseconds),
            retry: EvaluationRunner.RetryPolicy(maximumAttempts: scenario.retryMaximumAttempts,
                                                initialBackoff: .milliseconds(1), multiplier: 1,
                                                maximumBackoff: .milliseconds(1)),
            entryLimit: scenario.entryLimit, bootstrapResamples: scenario.bootstrapResamples,
            bootstrapSeed: scenario.bootstrapSeed, pricing: nil)
        let configurationSummary = ConfigurationSummary(profileID: profile.profileID,
            profileVersion: profile.profileVersion, provider: "substitute", model: "stand-in-model",
            allowCloud: false, maximumConcurrency: scenario.maximumConcurrency,
            entryLimit: scenario.entryLimit,
            perRequestTimeoutMilliseconds: scenario.perRequestTimeoutMilliseconds,
            retryMaximumAttempts: scenario.retryMaximumAttempts,
            bootstrapResamples: scenario.bootstrapResamples, bootstrapSeed: scenario.bootstrapSeed,
            pricingID: nil)

        // Built outside the detached task: `MappingAnswering` is Sendable, and the
        // closure should capture values rather than the harness's own state.
        let references = Dictionary(uniqueKeysWithValues: fixture.dataset.records.map { ($0.recordID, $0) })
        let fallback = SubstituteAnswer(delay: .milliseconds(scenario.simulatedLatencyMilliseconds),
                                        reportedLatencyMilliseconds: scenario.simulatedLatencyMilliseconds)
        let answers = faultAnswers(scenario: scenario, records: fixture.dataset.records)
        let answerer = SubstituteAnswerer(references: references, answers: answers, fallback: fallback)
        let dataset = fixture.dataset

        // The gate makes "cancel before the first request" deterministic: without
        // it, a fast task could finish every batch before the parent cancelled it.
        let gate = StartGate()
        let runTask = Task.detached {
            await gate.wait()
            return try await EvaluationRunner.run(dataset: dataset, answerer: answerer,
                                                  configuration: configuration)
        }
        switch scenario.cancelAfterMilliseconds {
        case .some(0):
            runTask.cancel()
            await gate.release()
        case .some(let milliseconds):
            await gate.release()
            try await Task.sleep(for: .milliseconds(milliseconds))
            runTask.cancel()
        case .none:
            await gate.release()
        }
        let run = try await runTask.value

        let artifactStart = EvaluationStageTimings.now()
        let artifact = try run.export()
        let artifactMilliseconds = EvaluationStageTimings.milliseconds(from: artifactStart)
        let totalMilliseconds = EvaluationStageTimings.milliseconds(from: measuredStart)

        var stages: [EvaluationStageMeasurement] = [
            .init(stage: .fixturePreparation, wallClockMilliseconds: fixture.constructionMilliseconds,
                  observationCount: fixture.dataset.records.count, kind: .measured),
        ]
        stages += run.stages.stages.filter { !$0.stage.isHarnessOwned }
        stages.append(.init(stage: .artifactSerialization, wallClockMilliseconds: artifactMilliseconds,
                            observationCount: artifact.count, kind: .measured))
        let stageTimings = EvaluationStageTimings(stages: stages,
                                                   totalWallClockMilliseconds: totalMilliseconds)

        let memory: BenchmarkMemory
        if memoryIsolated, let peak = ProcessMemory.peakResidentBytes(), peak > 0 {
            memory = BenchmarkMemory(peakResidentBytes: peak, kind: .measured, unavailableReason: nil,
                                     scope: "process-lifetime ru_maxrss; one scenario per process")
        } else {
            memory = BenchmarkMemory(peakResidentBytes: nil, kind: .unavailable,
                                     unavailableReason: memoryIsolated
                                         ? "ru_maxrss was not available on this host"
                                         : "shared process: ru_maxrss is a lifetime maximum, not per-scenario",
                                     scope: "process-lifetime ru_maxrss; one scenario per process")
        }

        let fixtureIdentity = FixtureIdentity(fixtureID: fixture.fixtureID, fixtureSeed: spec.seed,
            fixtureVersion: spec.version, recordCount: spec.recordCount, clusterCount: spec.clusterCount,
            totalRecordCount: spec.totalRecordCount, countableRecords: fixture.countableRecords,
            promptRecordCount: spec.promptRecordCount, removedRecordCount: spec.removedRecordCount)
        let reportSummary = ReportSummary(cases: run.report.cases, clusters: run.report.clusters,
            isQualityClaimAllowed: run.report.isQualityClaimAllowed,
            claimBlockerKinds: run.report.claimBlockers.map(\.kind.rawValue),
            countableRecords: run.report.dataset.countableRecords,
            pendingAdjudication: run.report.dataset.pendingAdjudication,
            unaccountedRecords: run.report.dataset.unaccountedRecords.count)
        let benchmarkID = EvaluationBenchmarkFixture.digest("\(spec.id)|\(scenario.material)")

        return Result(schemaVersion: schemaVersion, benchmarkID: benchmarkID,
                      measurementID: UUID().uuidString, executedAt: executedAt,
                      fixture: fixtureIdentity, scenario: scenario, configuration: configurationSummary,
                      stageTimings: stageTimings, telemetry: run.telemetry, runID: run.runID,
                      identity: run.identity, boundary: run.boundary, report: reportSummary,
                      memory: memory, environment: environment, limitations: limitations)
    }

    // MARK: - Fault injection

    /// A per-record behaviour roll. `SubstituteAnswerer` decides a batch by its
    /// first entry, so this is a per-*request* rate whatever the entry limit is;
    /// the record order is the fixture's fixed order, so the roll is reproducible.
    private static func faultAnswers(scenario: Scenario, records: [GoldRecord]) -> [UUID: SubstituteAnswer] {
        var generator = SplitMix64(seed: scenario.fixtureSeed ^ 0xD1B5_4A32_D192_ED03)
        var answers: [UUID: SubstituteAnswer] = [:]
        for record in records {
            let roll = Double(generator.next() >> 11) / Double(1 << 53)
            let affected = roll < scenario.faultRate
            let sourceID = EvaluationFixture.sourceID(for: record.recordID)
            answers[sourceID] = Self.answer(for: scenario, affected: affected)
        }
        return answers
    }

    private static func answer(for scenario: Scenario, affected: Bool) -> SubstituteAnswer {
        let delay = Duration.milliseconds(scenario.simulatedLatencyMilliseconds)
        let reported = scenario.simulatedLatencyMilliseconds
        switch scenario.faultMode {
        case .success, .cancelled, .notIssued:
            return SubstituteAnswer(delay: delay, reportedLatencyMilliseconds: reported)
        case .partial:
            return SubstituteAnswer(withhold: affected ? [.documenttype, .biddeadline] : [],
                                    delay: delay, reportedLatencyMilliseconds: reported)
        case .retry:
            return SubstituteAnswer(failure: affected ? .invalidResponse : nil,
                                    delay: delay, reportedLatencyMilliseconds: reported)
        case .timeout:
            return SubstituteAnswer(failure: affected ? .timeout : nil,
                                    delay: delay, reportedLatencyMilliseconds: reported)
        case .permanentUnavailable:
            // A stand-in has no provider credential; that is the honest
            // non-retryable refusal the offline path can express.
            return SubstituteAnswer(failure: affected ? .credentialMissing : nil,
                                    delay: delay, reportedLatencyMilliseconds: reported)
        case .delayed:
            let longer = affected ? Duration.milliseconds(reported * 4) : delay
            return SubstituteAnswer(delay: longer,
                                    reportedLatencyMilliseconds: affected ? reported * 4 : reported)
        }
    }
}

// MARK: - Process observations

/// `ru_maxrss` is a process-lifetime maximum; on macOS it is already in bytes.
/// A zero is treated as "not observed" rather than published as a measurement.
private enum ProcessMemory {
    static func peakResidentBytes() -> Int? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else { return nil }
        return Int(usage.ru_maxrss)
    }
}

/// A one-shot gate: the run task waits at its first statement, so cancelling it
/// before releasing the gate is deterministic rather than a scheduler race.
private actor StartGate {
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending = continuation
        }
    }

    func release() {
        released = true
        pending?.resume()
        pending = nil
    }
}