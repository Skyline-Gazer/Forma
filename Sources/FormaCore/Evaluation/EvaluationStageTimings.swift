import Foundation

// Where the time in a benchmark went, and what each number is allowed to mean.
//
// A run's total is not the sum of its parts, and a benchmark that prints one
// without the other invites the reader to add them up. So this file states two
// separate facts: `totalWallClockMilliseconds`, measured around the whole
// execution, and `sumOfStageMilliseconds`, which is only ever a lower bound on it
// (dataset construction, sample preparation and the clock reads themselves sit
// outside the stages). `unaccountedMilliseconds` is the difference, so a reader
// can see how much of the run the stages actually explain instead of assuming
// they explain all of it.
//
// The stages are sequential by construction - planning, execution, validation,
// judgement, report - so their sum is meaningful; the harness-owned stages
// (fixture preparation and artifact serialization) sit outside the run's own
// clock and are measured by the harness. Nothing here overlaps: if a future
// change made two stages run concurrently, the sum would silently become wrong,
// which is why the type exposes the total separately rather than letting callers
// reconstruct it.

/// One measurable part of a benchmark execution.
///
/// The stage list is DevBox-First §4.2's 扫描/解析/映射阶段耗时数据结构, split
/// into the stages the offline runner can actually time (no scan, no extraction:
/// those remain M9). The eighth item of the matrix - total elapsed time - is not
/// a stage but `EvaluationStageTimings.totalWallClockMilliseconds`.
public enum EvaluationStage: String, Codable, Sendable, CaseIterable {
    /// Building the synthetic dataset (fixture). Measured by the harness, because
    /// no fixture exists inside `EvaluationRunner`.
    case fixturePreparation = "fixture_preparation"
    /// `MappingEngine.plannedBatches` and the context it groups by.
    case batchPlanning = "batch_planning"
    /// Every issued request: the deadline race, the retries, the backoff.
    case requestExecution = "request_execution"
    /// `ManifestValidator`: the twelve-field verdict per entry.
    case manifestValidation = "manifest_validation"
    /// `CaseJudgement`: one judgement per sample.
    case caseJudgement = "case_judgement"
    /// `EvaluationReport` and the slices and intervals it draws.
    case reportAndMetrics = "report_and_metrics"
    /// Encoding the exportable artifact. Measured by the harness, because the
    /// runner returns a value rather than writing bytes.
    case artifactSerialization = "artifact_serialization"

    /// Stages the runner itself cannot time: they happen outside `run`.
    public var isHarnessOwned: Bool {
        switch self {
        case .fixturePreparation, .artifactSerialization: return true
        default: return false
        }
    }
}

/// One stage's duration, its observation count, and where the number came from.
///
/// `kind` describes how the *duration* was obtained - `.measured` when this
/// process's monotonic clock timed the stage, `.unavailable` when the stage did
/// not run - and deliberately says nothing about whether the answers inside it
/// were real: a stand-in run still measures real wall clock, and that is
/// `EvaluationRunIdentity.isSubstitute` to disclose.
public struct EvaluationStageMeasurement: Codable, Sendable, Equatable {
    public let stage: EvaluationStage
    /// Nil when the stage did not run. Never 0: "took no time" and "did not
    /// happen" are different statements.
    public let wallClockMilliseconds: Int?
    /// What the stage did, counted the way that stage counts it: records for a
    /// fixture, entries for planning and validation, requests for execution,
    /// samples for judgement and report, one artifact for serialization.
    public let observationCount: Int
    public let kind: MeasurementKind
    public let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case stage, wallClockMilliseconds = "wall_clock_milliseconds"
        case observationCount = "observation_count", kind, unavailableReason = "unavailable_reason"
    }

    public init(stage: EvaluationStage, wallClockMilliseconds: Int?, observationCount: Int,
                kind: MeasurementKind, unavailableReason: String? = nil) {
        self.stage = stage
        self.wallClockMilliseconds = wallClockMilliseconds
        self.observationCount = observationCount
        self.kind = kind
        self.unavailableReason = wallClockMilliseconds == nil ? (unavailableReason ?? "stage did not run") : nil
    }

    public var isObserved: Bool { wallClockMilliseconds != nil }

    /// The measurement for a stage that did not run, stated rather than omitted:
    /// a missing row reads as "not measured" and an absent stage as "not part of
    /// this benchmark", which are different facts.
    public static func notRun(_ stage: EvaluationStage, observations: Int = 0, reason: String) -> Self {
        EvaluationStageMeasurement(stage: stage, wallClockMilliseconds: nil, observationCount: observations,
                                   kind: .unavailable, unavailableReason: reason)
    }
}

/// The stages of one execution, the total they sit inside, and the part of that
/// total no stage explains.
public struct EvaluationStageTimings: Codable, Sendable, Equatable {
    public let stages: [EvaluationStageMeasurement]
    /// Measured around the whole execution, not assembled from the stages.
    public let totalWallClockMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case stages, totalWallClockMilliseconds = "total_wall_clock_milliseconds"
    }

    public init(stages: [EvaluationStageMeasurement], totalWallClockMilliseconds: Int) {
        self.stages = stages
        self.totalWallClockMilliseconds = max(0, totalWallClockMilliseconds)
    }

    public func measurement(for stage: EvaluationStage) -> EvaluationStageMeasurement? {
        stages.first { $0.stage == stage }
    }

    /// Sum of the stages, or nil when any recorded stage was not observed: a
    /// partial sum would be the wrong number presented as the right one.
    public var sumOfStageMilliseconds: Int? {
        guard !stages.isEmpty, stages.allSatisfy(\.isObserved) else { return nil }
        return stages.reduce(0) { $0 + ($1.wallClockMilliseconds ?? 0) }
    }

    /// What the total contains that no stage explains. Zero is a real answer: it
    /// says the stages cover the whole run.
    public var unaccountedMilliseconds: Int? {
        guard let sum = sumOfStageMilliseconds else { return nil }
        return max(0, totalWallClockMilliseconds - sum)
    }

    /// The clock the runner and the harness share.
    ///
    /// Monotonic (`ContinuousClock`), so a wall-clock adjustment cannot make a
    /// stage look shorter than it was, and the same clock as `EvaluationTelemetry`'s
    /// throughput, so a stage duration and a run duration are comparable.
    public static func now() -> ContinuousClock.Instant { ContinuousClock.now }

    public static func milliseconds(from start: ContinuousClock.Instant) -> Int {
        Int(EvaluationRunner.RetryPolicy.milliseconds(start.duration(to: .now)))
    }
}