import Darwin
import Foundation
import FormaCore

// FormaBenchmark — the opt-in entry point for the offline runner scale benchmark.
//
// This is deliberately an executable target, not a test: `swift test` never runs
// it, no wall-clock assertion can turn a slow hosted runner into a red PR, and
// the regular CI job does not have to compile it. The benchmark workflow builds
// and runs it explicitly. One scenario per process is the normal mode, because
// macOS `ru_maxrss` is a process-lifetime maximum: with several scenarios in one
// process, a per-scenario peak RSS cannot be attributed honestly and is reported
// as unavailable instead.

// MARK: - Arguments

/// All CLI state is local to `parse()`: `Scenario` is immutable by design, so
/// the flags are collected into plain values and the cell is built once.
struct Arguments {
    var label = "smoke"
    var recordCount = 100
    var clusterCount = 10
    var entryLimit = 25
    var maximumConcurrency = 4
    var faultMode: EvaluationBenchmark.FaultMode = .success
    var faultRate = 0.0
    var simulatedLatencyMilliseconds = 2
    var bootstrapResamples = 20
    var bootstrapSeed: UInt64 = 7
    var fixtureSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var promptRecordCount = 0
    var removedRecordCount = 0
    var perRequestTimeoutMilliseconds = 5_000
    var retryMaximumAttempts = 1
    var cancelAfterMilliseconds: Int? = nil
    var sweep = false
    var jsonPath: String?
    var baselinePath: String?
    var runner = "local"
    var swiftVersion: String?
    var xcodeVersion: String?

    var scenario: EvaluationBenchmark.Scenario {
        EvaluationBenchmark.Scenario(
            label: label, recordCount: recordCount, clusterCount: clusterCount,
            entryLimit: entryLimit, maximumConcurrency: maximumConcurrency, faultMode: faultMode,
            faultRate: faultRate, simulatedLatencyMilliseconds: simulatedLatencyMilliseconds,
            bootstrapResamples: bootstrapResamples, bootstrapSeed: bootstrapSeed,
            fixtureSeed: fixtureSeed, promptRecordCount: promptRecordCount,
            removedRecordCount: removedRecordCount,
            perRequestTimeoutMilliseconds: perRequestTimeoutMilliseconds,
            retryMaximumAttempts: retryMaximumAttempts,
            cancelAfterMilliseconds: cancelAfterMilliseconds)
    }

    static let usage = """
    FormaBenchmark — offline runner scale benchmark (no provider, no file scan)

      --records N                 evaluation records (100 / 1000 / 10000)
      --clusters K                project clusters
      --concurrency C             request concurrency ceiling (1 / 2 / 4 / 8)
      --entry-limit L             MappingEngine batch entry limit (25 / 100)
      --fault MODE                success|retry|timeout|permanent_unavailable|delayed|partial|cancelled|not_issued
      --fault-rate R              fraction of requests the fault applies to (0...1)
      --latency-ms N              simulated stand-in latency per request
      --bootstrap N               cluster bootstrap resamples (keep small at 10k)
      --seed N                    fixture seed
      --prompt N                  few-shot records on the prompt side
      --removed N                 withdrawn records
      --timeout-ms N              per-request deadline
      --retries N                 maximum attempts per request
      --cancel-after-ms N         cancel the run after N ms (0 = before the first request)
      --label S                   cell label
      --sweep                     run the smoke matrix in one process (peak RSS unavailable)
      --json PATH                 write machine-readable JSON (an array of results)
      --baseline PATH             report ratios against a previous JSON run (never a gate)
      --runner S                  runner label (default "local")
      --swift-version S           toolchain string recorded in the result
      --xcode-version S           Xcode string recorded in the result
    """

    static func parse() throws -> Arguments {
        var a = Arguments()
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        func next() throws -> String {
            guard index + 1 < args.count else { throw FormaError.invalidSource }
            index += 1
            return args[index]
        }
        func integer() throws -> Int {
            guard let value = Int(try next()) else { throw FormaError.invalidSource }
            return value
        }
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--help", "-h": print(usage); exit(0)
            case "--records": a.recordCount = try integer()
            case "--clusters": a.clusterCount = try integer()
            case "--concurrency": a.maximumConcurrency = try integer()
            case "--entry-limit": a.entryLimit = try integer()
            case "--fault":
                guard let mode = EvaluationBenchmark.FaultMode(rawValue: try next()) else {
                    throw FormaError.invalidSource
                }
                a.faultMode = mode
            case "--fault-rate": a.faultRate = Double(try next()) ?? 0
            case "--latency-ms": a.simulatedLatencyMilliseconds = try integer()
            case "--bootstrap": a.bootstrapResamples = try integer()
            case "--seed": a.fixtureSeed = UInt64(try next()) ?? 0
            case "--prompt": a.promptRecordCount = try integer()
            case "--removed": a.removedRecordCount = try integer()
            case "--timeout-ms": a.perRequestTimeoutMilliseconds = try integer()
            case "--retries": a.retryMaximumAttempts = try integer()
            case "--cancel-after-ms": a.cancelAfterMilliseconds = try integer()
            case "--label": a.label = try next()
            case "--sweep": a.sweep = true
            case "--json": a.jsonPath = try next()
            case "--baseline": a.baselinePath = try next()
            case "--runner": a.runner = try next()
            case "--swift-version": a.swiftVersion = try next()
            case "--xcode-version": a.xcodeVersion = try next()
            default:
                FileHandle.standardError.write(Data("unknown option \(flag)\n\(usage)\n".utf8))
                exit(2)
            }
            index += 1
        }
        return a
    }

    /// The smoke matrix: a concurrency sweep, every injected fault, and both
    /// interruption shapes. Kept at 100 records so a PR job stays light.
    var sweepScenarios: [EvaluationBenchmark.Scenario] {
        var cells: [EvaluationBenchmark.Scenario] = []
        for concurrency in [1, 2, 4, 8] {
            cells.append(scenario.rebuilt(label: "smoke-c\(concurrency)",
                                          maximumConcurrency: concurrency))
        }
        for mode in EvaluationBenchmark.FaultMode.allCases {
            let cancel: Int? = mode == .notIssued ? 0 : (mode == .cancelled ? 5 : nil)
            cells.append(scenario.rebuilt(label: "fault-\(mode.rawValue)", faultMode: mode,
                                          faultRate: mode == .success ? 0 : 0.25,
                                          retryMaximumAttempts: mode == .retry ? 3 : 1,
                                          cancelAfterMilliseconds: cancel))
        }
        return cells
    }
}

private extension EvaluationBenchmark.Scenario {
    func rebuilt(label: String? = nil, recordCount: Int? = nil, clusterCount: Int? = nil,
                 entryLimit: Int? = nil, maximumConcurrency: Int? = nil,
                 faultMode: EvaluationBenchmark.FaultMode? = nil, faultRate: Double? = nil,
                 retryMaximumAttempts: Int? = nil,
                 cancelAfterMilliseconds: Int?? = nil) -> Self {
        EvaluationBenchmark.Scenario(
            label: label ?? self.label, recordCount: recordCount ?? self.recordCount,
            clusterCount: clusterCount ?? self.clusterCount, entryLimit: entryLimit ?? self.entryLimit,
            maximumConcurrency: maximumConcurrency ?? self.maximumConcurrency,
            faultMode: faultMode ?? self.faultMode, faultRate: faultRate ?? self.faultRate,
            simulatedLatencyMilliseconds: self.simulatedLatencyMilliseconds,
            bootstrapResamples: self.bootstrapResamples, bootstrapSeed: self.bootstrapSeed,
            fixtureSeed: self.fixtureSeed, promptRecordCount: self.promptRecordCount,
            removedRecordCount: self.removedRecordCount,
            perRequestTimeoutMilliseconds: self.perRequestTimeoutMilliseconds,
            retryMaximumAttempts: retryMaximumAttempts ?? self.retryMaximumAttempts,
            cancelAfterMilliseconds: cancelAfterMilliseconds ?? self.cancelAfterMilliseconds)
    }
}

// MARK: - Reporting

func column(_ value: String, _ width: Int) -> String {
    value.count >= width ? String(value.prefix(width)) : value + String(repeating: " ", count: width - value.count)
}

func summary(_ results: [EvaluationBenchmark.Result]) -> String {
    var lines: [String] = []
    lines.append("FormaBenchmark — synthetic runner scale (NOT a file scan, NOT a provider benchmark)")
    lines.append(column("cell", 28) + column("samples", 9) + column("req", 7) + column("issued", 8)
        + column("attempt", 9) + column("retry", 7) + column("failed", 8) + column("obs.max", 9)
        + column("wall ms", 9) + column("samples/s", 11) + column("peak MB", 9))
    for r in results {
        let t = r.telemetry
        let throughput = t.throughputSamplesPerSecond.map { String(format: "%.1f", $0) } ?? "n/a"
        let peak = r.memory.peakResidentBytes.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "n/a"
        lines.append(column(r.scenario.label, 28) + column(String(t.sampleCount), 9)
            + column(String(t.requestCount), 7) + column(String(t.issuedRequestCount), 8)
            + column(String(t.attemptCount), 9) + column(String(t.retryCount), 7)
            + column(String(t.failedRequests), 8) + column(String(t.observedConcurrency), 9)
            + column(String(t.wallClockMilliseconds), 9) + column(throughput, 11) + column(peak, 9))
    }
    for r in results {
        let sum = r.stageTimings.sumOfStageMilliseconds.map(String.init) ?? "n/a"
        let gap = r.stageTimings.unaccountedMilliseconds.map(String.init) ?? "n/a"
        lines.append("  \(r.scenario.label): total=\(r.stageTimings.totalWallClockMilliseconds)ms "
            + "stage-sum=\(sum)ms (lower bound) unaccounted=\(gap)ms "
            + "identity=\(r.benchmarkID.prefix(12)) measurement=\(r.measurementID.prefix(8))")
    }
    return lines.joined(separator: "\n")
}

/// Ratios against an earlier run, for an explainable regression conversation.
/// This never decides the exit code: a shared hosted runner's wall clock is not a
/// PR gate.
func baselineReport(_ results: [EvaluationBenchmark.Result], _ path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let previous = try? FormaJSON.decode([EvaluationBenchmark.Result].self, from: data) else {
        return "baseline \(path) could not be decoded; no ratios reported"
    }
    var before: [String: EvaluationBenchmark.Result] = [:]
    for item in previous { before[item.benchmarkID] = item }
    var lines = ["Baseline comparison (report only, never a gate):"]
    for r in results {
        guard let old = before[r.benchmarkID] else {
            lines.append("  \(r.scenario.label): no matching logical benchmark in baseline")
            continue
        }
        let now = Double(r.stageTimings.totalWallClockMilliseconds)
        let was = Double(old.stageTimings.totalWallClockMilliseconds)
        let ratio = was > 0 ? now / was : nil
        let text = ratio.map { String(format: "%.2fx", $0) } ?? "n/a"
        lines.append("  \(r.scenario.label): \(Int(was))ms -> \(Int(now))ms (\(text))"
            + (ratio.map { $0 > 1.5 ? "  [review: >1.5x]" : "" } ?? ""))
    }
    return lines.joined(separator: "\n")
}

// MARK: - Entry point

let options = try Arguments.parse()
let environment = EvaluationBenchmark.BenchmarkEnvironment.current(
    runner: options.runner, swiftVersion: options.swiftVersion, xcodeVersion: options.xcodeVersion)
let cells = options.sweep ? options.sweepScenarios : [options.scenario]
var results: [EvaluationBenchmark.Result] = []
for cell in cells {
    let result = try await EvaluationBenchmark.execute(
        cell, environment: environment, memoryIsolated: !options.sweep)
    results.append(result)
}

print(summary(results))
if let path = options.baselinePath { print(baselineReport(results, path)) }

let violations = results.flatMap { result in
    result.violations().map { "[\(result.scenario.label)] \($0)" }
}
if !violations.isEmpty {
    FileHandle.standardError.write(Data(("Benchmark contract violations:\n"
        + violations.map { "  - \($0)" }.joined(separator: "\n") + "\n").utf8))
}

if let path = options.jsonPath {
    let data = try FormaJSON.encode(results, pretty: true)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    print("JSON: \(path) (\(data.count) bytes, \(results.count) measurement(s))")
}
print("Environment: \(environment.osVersion), \(environment.processorCount) cores, "
    + "\(environment.machineModel ?? "unknown model"), "
    + "swift=\(environment.swiftVersion ?? "not supplied"), xcode=\(environment.xcodeVersion ?? "not supplied")")
print("Limitations: " + EvaluationBenchmark.limitations.joined(separator: " | "))

exit(violations.isEmpty ? 0 : 1)