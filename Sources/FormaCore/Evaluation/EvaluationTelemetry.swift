import Foundation

// What a run reports about its own execution, and where each number came from.
//
// PLAN §8.2 asks the report to state 每批/每文件 token、请求次数、平均/P95 延迟、
// 错误率、并发, and the cost with 计价日期/币种/单价来源. The arithmetic is the easy
// part. The hard part is that a deterministic stand-in and a real provider produce
// the *same* arithmetic from different facts: a stand-in's token count is a number
// someone typed, and its latency is a sleep. So every published number here carries
// a `MeasurementKind`, and that kind - not the number - is what a reader and the
// report gate act on.
//
// Three rules are structural rather than documented-and-hoped:
//
// 1. A count nobody reported is `nil`, never zero. `TokenUsage.unavailable` is a
//    different value from `TokenUsage(input: 0, output: 0)`, and the two may not
//    be summed into one another.
// 2. Provenance never improves by combination: summing a measured count with a
//    simulated one yields a simulated count, because the result contains a number
//    no provider reported.
// 3. Nothing here invents a price. `TokenPricing` is an input the caller states;
//    FormaCore ships no price list, because a wrong price published as a run
//    property is worse than no cost at all.

/// Where a number came from.
public enum MeasurementKind: String, Codable, Sendable, CaseIterable {
    /// The provider reported this count, and the run really did talk to it.
    case measured
    /// A deterministic stand-in produced this count. Exercising the harness with a
    /// stand-in is authorised P3-A work; quoting its numbers as a model's is not.
    case simulated
    /// Scaled from a measured amount to a size the run never executed.
    /// `1000/N × 实测费用` in PLAN §8.2's wording: a projection, never a spend.
    case extrapolated
    /// Nothing reported a value, so there is no number. Never read as zero.
    case unavailable

    /// Ordering used when two counts are combined. Lower is weaker: a result may
    /// never claim a stronger provenance than its weakest input.
    var rank: Int {
        switch self {
        case .unavailable: 0
        case .extrapolated: 1
        case .simulated: 2
        case .measured: 3
        }
    }

    /// The provenance of a sum. `.unavailable` is the identity element rather than
    /// the weakest value: a run whose one half reported nothing and whose other
    /// half is measured still reports what it measured, with the unreported half
    /// absent from every field it belongs to.
    static func combined(_ lhs: MeasurementKind, _ rhs: MeasurementKind) -> MeasurementKind {
        switch (lhs, rhs) {
        case (.unavailable, let other): return other
        case (let mine, .unavailable): return mine
        default: return lhs.rank <= rhs.rank ? lhs : rhs
        }
    }
}

/// Token counts for one unit of work, with the fact that produced them.
///
/// Each slot is independently optional because a provider that reports input and
/// output but no cache columns is common, and filling the missing columns with
/// zero would turn "not reported" into a measured zero in every total.
public struct TokenUsage: Codable, Sendable, Equatable {
    public let input: Int?
    public let output: Int?
    public let cacheRead: Int?
    public let cacheCreation: Int?
    public let kind: MeasurementKind

    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheCreation: Int? = nil,
                kind: MeasurementKind) {
        // A negative count is a sign error in whoever produced it; it is dropped
        // rather than propagated, because it would subtract from a total.
        func counted(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
        let input = counted(input), output = counted(output)
        let cacheRead = counted(cacheRead), cacheCreation = counted(cacheCreation)
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        // A declared `measured` count with nothing in it is not a measurement, and
        // keeping the claim would let a caller filter on `kind` and read zeros.
        self.kind = (input == nil && output == nil && cacheRead == nil && cacheCreation == nil)
            ? .unavailable : kind
    }

    public static let unavailable = TokenUsage(kind: .unavailable)

    /// What a stand-in reports. The numbers are stated by whoever wrote the
    /// scenario, which is exactly why the kind is `simulated` and not `measured`.
    public static func simulated(input: Int, output: Int, cacheRead: Int = 0, cacheCreation: Int = 0)
        -> TokenUsage {
        TokenUsage(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation,
                   kind: .simulated)
    }

    /// True when at least one column was reported.
    public var hasCounts: Bool { kind != .unavailable }

    /// Input plus output plus the cache columns. `nil` when neither side of the
    /// billable pair was reported, because a total built from one half of the pair
    /// would understate the request without saying so.
    public var total: Int? {
        guard let input, let output else { return nil }
        return input + output + (cacheRead ?? 0) + (cacheCreation ?? 0)
    }

    /// The sum of two usages. A slot reported by only one side keeps that side's
    /// number and stays as it is; a slot reported by neither stays nil. Provenance
    /// is the weaker of the two, never the stronger.
    public func added(to other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: Self.sum(self.input, other.input),
            output: Self.sum(self.output, other.output),
            cacheRead: Self.sum(self.cacheRead, other.cacheRead),
            cacheCreation: Self.sum(self.cacheCreation, other.cacheCreation),
            kind: MeasurementKind.combined(kind, other.kind))
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (let value?, nil): value
        case (nil, let value?): value
        case (let left?, let right?): left + right
        }
    }
}

/// One priced model, as the caller stated it.
///
/// PLAN §8.2 requires 计价日期/币种/单价来源 beside any cost, so those are fields
/// rather than prose: a cost whose price version cannot be named is not publishable.
/// FormaCore ships no prices - a stale or invented rate silently becomes the
/// run's cost figure - so the caller supplies the version it priced against.
public struct TokenPricing: Codable, Sendable, Equatable {
    /// Version identifier of the price set, e.g. `forma-token-pricing-1`.
    public let id: String
    public let provider: String
    public let modelID: String?
    public let currency: String
    /// The date the prices took effect, as `YYYY-MM-DD`.
    public let effectiveOn: String
    /// Where the numbers came from: a published price page, an agreement, an
    /// internal estimate. The reader has to be able to tell which.
    public let source: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheCreationPerMillion: Double

    public init(id: String, provider: String, modelID: String?, currency: String, effectiveOn: String,
                source: String, inputPerMillion: Double, outputPerMillion: Double,
                cacheReadPerMillion: Double = 0, cacheCreationPerMillion: Double = 0) {
        // A negative rate is a typo that would make a run look profitable; a
        // programme bug should stop the run, not be reported as a discount.
        precondition(inputPerMillion >= 0 && outputPerMillion >= 0
                         && cacheReadPerMillion >= 0 && cacheCreationPerMillion >= 0,
                     "a token price cannot be negative")
        self.id = id
        self.provider = provider
        self.modelID = modelID
        self.currency = currency
        self.effectiveOn = effectiveOn
        self.source = source
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheCreationPerMillion = cacheCreationPerMillion
    }

    func cost(of usage: TokenUsage) -> Double? {
        guard let input = usage.input, let output = usage.output else { return nil }
        let cacheRead = usage.cacheRead ?? 0
        let cacheCreation = usage.cacheCreation ?? 0
        let amount = (Double(input) / 1_000_000) * inputPerMillion
            + (Double(output) / 1_000_000) * outputPerMillion
            + (Double(cacheRead) / 1_000_000) * cacheReadPerMillion
            + (Double(cacheCreation) / 1_000_000) * cacheCreationPerMillion
        return amount
    }
}

/// What a run cost, what produced the figure, and the projection PLAN §8.2 asks
/// for beside it.
public struct CostEstimate: Codable, Sendable, Equatable {
    /// A projection to a size the run never executed. PLAN §8.2: `1000/N × 实测费用`,
    /// 不把外推称实测 - so the kind is always `.extrapolated`, and `basis` says which
    /// weaker number it was scaled from.
    public struct Extrapolation: Codable, Sendable, Equatable {
        public let sampleCount: Int
        public let amount: Double
        /// The provenance of the amount this was scaled from. A projection of a
        /// stand-in's cost is still not a price anyone paid.
        public let basis: MeasurementKind
        public let assumption: String

        enum CodingKeys: String, CodingKey {
            case sampleCount = "sample_count", amount, basis, assumption
        }
    }

    public let kind: MeasurementKind
    /// The price set applied, or `unpriced` when no pricing was supplied. A cost
    /// without a price version is not a number a reviewer can check.
    public let pricingID: String
    public let currency: String
    /// nil when there is nothing to price: no usage reported, or no price set.
    public let amount: Double?
    public let usage: TokenUsage
    public let thousandSampleExtrapolation: Extrapolation?

    enum CodingKeys: String, CodingKey {
        case kind, pricingID = "pricing_id", currency, amount, usage
        case thousandSampleExtrapolation = "thousand_sample_extrapolation"
    }

    /// True only when a real provider's usage was priced. A stand-in run's cost is
    /// never spend, whatever the number looks like.
    public var isRealSpend: Bool { kind == .measured }

    public static let unpriced = "unpriced"

    /// Price `usage` with `pricing`, and project `1000/N × 实测费用` when there is
    /// something to project. `sampleCount` is the denominator N: the number of
    /// samples the run actually executed, so a projection from three records says
    /// it was scaled from three.
    public static func estimate(usage: TokenUsage, pricing: TokenPricing?, sampleCount: Int) -> CostEstimate {
        guard let pricing, usage.hasCounts else {
            return CostEstimate(kind: .unavailable, pricingID: pricing?.id ?? unpriced,
                                currency: pricing?.currency ?? "unknown", amount: nil, usage: usage,
                                thousandSampleExtrapolation: nil)
        }
        guard let amount = pricing.cost(of: usage) else {
            return CostEstimate(kind: .unavailable, pricingID: pricing.id, currency: pricing.currency,
                                amount: nil, usage: usage, thousandSampleExtrapolation: nil)
        }
        var projection: Extrapolation?
        if sampleCount >= 1 {
            projection = Extrapolation(
                sampleCount: sampleCount,
                amount: amount * (1_000 / Double(sampleCount)),
                basis: usage.kind,
                assumption: "linear in sample count at \(sampleCount) samples, holding per-sample "
                    + "requests, retry rate and token mix constant")
        }
        return CostEstimate(kind: usage.kind, pricingID: pricing.id, currency: pricing.currency,
                            amount: amount, usage: usage, thousandSampleExtrapolation: projection)
    }
}

/// Latency over the requests a run issued, with the fact that produced it.
///
/// The percentile convention is the one `ClusterBootstrap` already uses
/// (`sorted[Int(Double(count - 1) * q)]`), so a band and a latency figure quoted in
/// one report are computed the same way rather than by two conventions that agree
/// at large N and disagree at the sample sizes an offline run actually has.
public struct LatencyDistribution: Codable, Sendable, Equatable {
    public let kind: MeasurementKind
    /// How many requests contributed a latency. Zero means none did, and every
    /// percentile is then nil rather than 0.
    public let sampleCount: Int
    public let averageMilliseconds: Double?
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let maximumMilliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case kind, sampleCount = "sample_count", averageMilliseconds = "average_milliseconds"
        case p50Milliseconds = "p50_milliseconds", p95Milliseconds = "p95_milliseconds"
        case maximumMilliseconds = "maximum_milliseconds"
    }

    public init(samples: [Int], kind: MeasurementKind) {
        let measured = samples.filter { $0 >= 0 }.map(Double.init)
        self.kind = measured.isEmpty ? .unavailable : kind
        self.sampleCount = measured.count
        guard !measured.isEmpty else {
            averageMilliseconds = nil
            p50Milliseconds = nil
            p95Milliseconds = nil
            maximumMilliseconds = nil
            return
        }
        let sorted = measured.sorted()
        averageMilliseconds = measured.reduce(0, +) / Double(measured.count)
        p50Milliseconds = Self.percentile(sorted, 0.50)
        p95Milliseconds = Self.percentile(sorted, 0.95)
        maximumMilliseconds = sorted.last
    }

    static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        sorted[Int(Double(sorted.count - 1) * quantile)]
    }
}

/// Time to first token, when something actually observed one.
///
/// A non-streaming request has exactly one observation - the whole response - and
/// reporting it as TTFT would make a slow non-streaming provider look like it had
/// a fast first token. So this type is empty unless an answerer reports a first
/// token explicitly, and `isObservable` is what a report reads before printing a
/// column. `MappingAttempt.timeToFirstTokenMilliseconds` is the only path in, and
/// the live client never sets it.
public struct FirstTokenLatency: Codable, Sendable, Equatable {
    public let kind: MeasurementKind
    public let sampleCount: Int
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case kind, sampleCount = "sample_count", p50Milliseconds = "p50_milliseconds"
        case p95Milliseconds = "p95_milliseconds"
    }

    public init(samples: [Int], kind: MeasurementKind) {
        let observed = samples.filter { $0 >= 0 }.map(Double.init)
        self.kind = observed.isEmpty ? .unavailable : kind
        self.sampleCount = observed.count
        guard !observed.isEmpty else {
            p50Milliseconds = nil
            p95Milliseconds = nil
            return
        }
        let sorted = observed.sorted()
        p50Milliseconds = LatencyDistribution.percentile(sorted, 0.50)
        p95Milliseconds = LatencyDistribution.percentile(sorted, 0.95)
    }

    /// Nothing observed a first token: the run is non-streaming or the answerer
    /// does not report one. The report must print "not observed", never 0 ms.
    public var isObservable: Bool { kind != .unavailable }
}

/// One logical request as the runner executed it.
///
/// A request is a batch the engine would have sent; a sample is a gold record; an
/// attempt is one call to the answerer. The three counts in `EvaluationTelemetry`
/// are what keeps a retried request from reading as three samples, so the row
/// carries the same three numbers per request for a reader who wants to check the
/// arithmetic.
public struct EvaluationRequestObservation: Codable, Sendable, Equatable {
    /// The batch id the engine issued, which is also the request id.
    public let requestID: String
    public let candidateID: String?
    /// The gold records this request covered, in the batch's own order.
    public let recordIDs: [String]
    /// Calls made to the answerer for this request: the first ask, plus retries.
    public let attempts: Int
    /// Provider requests reported inside those attempts, including the live
    /// client's own repair round and rate-limit retry. A stand-in reports one.
    public let providerRequests: Int
    public let retried: Bool
    /// `MappingOutcome` raw value of the attempt that decided the request.
    public let outcome: String
    /// The error code, when the request ended in failure.
    public let errorCode: String?
    /// Wall clock for the whole request, retries and backoff included. This is
    /// what throughput is measured against.
    public let wallClockMilliseconds: Int
    /// Provider-reported latency of the deciding attempt, nil when it reported
    /// none. Not the same number as `wallClockMilliseconds`, and the two are
    /// deliberately both present.
    public let providerLatencyMilliseconds: Int?
    public let firstTokenMilliseconds: Int?
    public let usage: TokenUsage
    /// The request digest the same inputs would produce today: the bytes the
    /// privacy preview shows and the mapping request would carry.
    public let payloadDigest: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", candidateID = "candidate_id", recordIDs = "record_ids", attempts
        case providerRequests = "provider_requests", retried, outcome
        case errorCode = "error_code", wallClockMilliseconds = "wall_clock_milliseconds"
        case providerLatencyMilliseconds = "provider_latency_milliseconds"
        case firstTokenMilliseconds = "first_token_milliseconds", usage, payloadDigest = "payload_digest"
    }
}

/// The whole run's execution facts, beside the rates they produced.
public struct EvaluationTelemetry: Codable, Sendable, Equatable {
    /// Samples = gold records judged. The denominator the quality rates rest on,
    /// and the count a retry must never inflate.
    public let sampleCount: Int
    /// Requests = batches the engine planned.
    public let requestCount: Int
    /// Requests actually issued. Lower than `requestCount` when the run was
    /// cancelled before some batches were reached; never higher.
    public let issuedRequestCount: Int
    /// Attempts = calls to the answerer, first asks plus retries.
    public let attemptCount: Int
    /// Provider requests reported inside those attempts.
    public let providerRequestCount: Int
    public let retryCount: Int
    public let timedOutAttempts: Int
    public let cancelledAttempts: Int
    /// Requests whose deciding attempt answered without error.
    public let succeededRequests: Int
    public let failedRequests: Int
    /// The ceiling the runner enforced, and the highest number of requests it
    /// actually had in flight. A run that reports the first without the second
    /// would let a concurrency bug look like a configuration.
    public let maximumConcurrency: Int
    public let observedConcurrency: Int
    public let wallClockMilliseconds: Int
    /// Samples per second of the run's own wall clock. A harness fact about this
    /// execution, never a claim about a provider.
    public let throughputSamplesPerSecond: Double?
    public let usage: TokenUsage
    public let latency: LatencyDistribution
    public let firstToken: FirstTokenLatency
    public let cost: CostEstimate
    /// True when the run was cancelled before it finished.
    public let cancelled: Bool

    enum CodingKeys: String, CodingKey {
        case sampleCount = "sample_count", requestCount = "request_count"
        case issuedRequestCount = "issued_request_count", attemptCount = "attempt_count"
        case providerRequestCount = "provider_request_count", retryCount = "retry_count"
        case timedOutAttempts = "timed_out_attempts", cancelledAttempts = "cancelled_attempts"
        case succeededRequests = "succeeded_requests", failedRequests = "failed_requests"
        case maximumConcurrency = "maximum_concurrency", observedConcurrency = "observed_concurrency"
        case wallClockMilliseconds = "wall_clock_milliseconds"
        case throughputSamplesPerSecond = "throughput_samples_per_second"
        case usage, latency, firstToken, cost, cancelled
    }

    /// Failure rate over issued requests. A run that issued nothing has no rate:
    /// nil, not 0%.
    public var failureRate: Double? {
        guard issuedRequestCount > 0 else { return nil }
        return Double(failedRequests) / Double(issuedRequestCount)
    }

    /// Attempt-level retry rate: attempts beyond the first per issued request.
    public var retryRate: Double? {
        guard issuedRequestCount > 0 else { return nil }
        return Double(retryCount) / Double(issuedRequestCount)
    }
}