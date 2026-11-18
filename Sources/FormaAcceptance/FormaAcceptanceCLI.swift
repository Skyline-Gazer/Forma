import Foundation
import FormaCore

/// CLI for the M11 acceptance work.
///
/// `m11` is the synthetic acceptance (`docs/M11-SYNTHETIC-RUNBOOK.md`).
/// `m11-real` is the read-only real-directory acceptance
/// (`docs/M11-LEVEL4-RUNBOOK.md`): it scans one directory the owner named and
/// writes a private review sheet plus a sanitized summary into a separate
/// evidence directory.
///
/// Exit codes for `m11`: 0 = every case passed; 1 = at least one case failed;
/// 3 = nothing failed but at least one case was not verified; 2 = usage or
/// environment error.
///
/// Exit codes for `m11-real`: 0 = the run completed and the coverage is
/// complete; 3 = the run completed but the coverage is partial (an unreadable
/// subtree, an unreadable entry, a probe limit or a timeout); 2 = usage or
/// validation error.
@main
struct FormaAcceptanceCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            write("usage: FormaAcceptance m11 [--output <path>]\n")
            write("       FormaAcceptance m11-real --source <abs> --evidence-dir <abs> --dry-run "
                + "[--labels <abs>] [--profile <id>] [--max-entries <n>] [--deadline-seconds <n>]\n")
            exit(2)
        }
        switch arguments[1] {
        case "m11": await runSynthetic(arguments)
        case "m11-real": await runReal(arguments)
        default:
            write("usage: FormaAcceptance m11 [--output <path>]\n")
            write("       FormaAcceptance m11-real --source <abs> --evidence-dir <abs> --dry-run "
                + "[--labels <abs>] [--profile <id>] [--max-entries <n>] [--deadline-seconds <n>]\n")
            exit(2)
        }
    }

    // MARK: - Synthetic acceptance

    private static func runSynthetic(_ arguments: [String]) async {
        var output: URL?
        if let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count {
            output = URL(fileURLWithPath: arguments[index + 1])
        }
        do {
            let report = try await M11SyntheticAcceptance.run()
            let data = try FormaJSON.encode(report, pretty: true)
            if let output {
                try data.write(to: output, options: .atomic)
            }
            for item in report.cases {
                print("\(item.status.rawValue)\t\(item.id)\t\(item.title)\t\(item.detail)")
            }
            print("")
            print("policy \(report.policyVersion) digest \(report.policyDigest)")
            print("decisions digest \(report.decisionsDigest)")
            print(report.summary)
            if let output { print("report written to \(output.path)") }
            if report.failed > 0 { exit(1) }
            if report.notVerified > 0 { exit(3) }
            exit(0)
        } catch {
            write("M11 acceptance failed: \(error)\n")
            exit(2)
        }
    }

    // MARK: - Real directory acceptance

    private static func runReal(_ arguments: [String]) async {
        let options = Options(arguments: Array(arguments.dropFirst(2)))
        do {
            try options.validate()
            guard let sourcePath = options.sourcePath,
                  let evidencePath = options.evidenceDirectoryPath else {
                throw M11RealDirectoryAcceptance.Failure.missingArgument("--source, --evidence-dir")
            }
            // The strings are checked before they become URLs: a relative path
            // must be refused, not resolved against the current directory.
            let source = try M11RealDirectoryAcceptance.absoluteURL(
                from: sourcePath, kind: .source)
            let evidenceDirectory = try M11RealDirectoryAcceptance.absoluteURL(
                from: evidencePath, kind: .evidenceDirectory)
            let outcome: M11RealDirectoryAcceptance.Outcome
            if let labelPath = options.labelPath {
                let labelURL = try M11RealDirectoryAcceptance.absoluteURL(
                    from: labelPath, kind: .labels)
                let labels = try M11RealDirectoryAcceptance.loadLabels(from: labelURL)
                outcome = try M11RealDirectoryAcceptance.importLabels(
                    source: source, evidenceDirectory: evidenceDirectory,
                    labels: labels, dryRun: true)
                print("mode\tlabel-import")
            } else {
                let request = M11RealDirectoryAcceptance.Request(
                    source: source, evidenceDirectory: evidenceDirectory,
                    labels: [], profileID: options.profile,
                    maxEntries: options.maxEntries, deadlineSeconds: options.deadlineSeconds,
                    dryRun: true)
                outcome = try await M11RealDirectoryAcceptance.run(request)
                print("mode\tscan")
            }
            printReport(outcome)
            exit(outcome.summary.coverageState == "COMPLETE" ? 0 : 3)
        } catch let failure as M11RealDirectoryAcceptance.Failure {
            write("m11-real refused: \(failure.description)\n")
            exit(2)
        } catch {
            write("m11-real failed: \(error)\n")
            exit(2)
        }
    }

    private static func printReport(_ outcome: M11RealDirectoryAcceptance.Outcome) {
        let summary = outcome.summary
        print("policy\t\(summary.policyID)\t\(summary.policyVersion)\t\(summary.policyDigest)")
        print("coverage\t\(summary.coverageState)\tscan=\(summary.scanState)\t"
            + "discovered=\(summary.discovered)\tprobed=\(summary.probeCoverage.probed)"
            + "\tskipped=\(summary.probeCoverage.skipped)\tissues=\(summary.scanIssueCount)")
        print("decisions\tinclude=\(summary.include)\texclude=\(summary.exclude)"
            + "\treview=\(summary.review)\tdefer=\(summary.deferred)\tunaccounted=\(summary.unaccounted)")
        print("review\t\(summary.reviewProgress.state)\trequired=\(summary.reviewProgress.required)"
            + "\treviewed=\(summary.reviewProgress.reviewed)\tunreviewed=\(summary.reviewProgress.unreviewed)"
            + "\tkeep=\(summary.reviewProgress.keepSamples)")
        print("false-exclusion\t\(summary.falseExclusion.state)"
            + "\tnumerator=\(summary.falseExclusion.numerator.map { String($0) } ?? "n/a")"
            + "\tdenominator=\(summary.falseExclusion.denominator.map { String($0) } ?? "n/a")"
            + "\trate=\(summary.falseExclusion.rate.map { String(format: "%.4f", $0) } ?? "n/a")")
        print("onedrive\t\(outcome.oneDrive.state)")
        for name in outcome.artifactHashes.keys.sorted() {
            guard let hash = outcome.artifactHashes[name] else { continue }
            print("artifact\t\(name)\t\(hash)")
        }
        print("evidence\tSHA256SUMS written")
    }

    // MARK: - Options

    private struct Options {
        var sourcePath: String?
        var evidenceDirectoryPath: String?
        var labelPath: String?
        var profile = "project-archive"
        var maxEntries = 5_000
        var deadlineSeconds = 120
        var dryRun = false
        var unknownFlags: [String] = []

        init(arguments: [String]) {
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch flag {
                case "--source":
                    if let value { sourcePath = value }
                    index += 2
                case "--evidence-dir":
                    if let value { evidenceDirectoryPath = value }
                    index += 2
                case "--labels":
                    if let value { labelPath = value }
                    index += 2
                case "--profile":
                    if let value { profile = value }
                    index += 2
                case "--max-entries":
                    if let value, let parsed = Int(value) { maxEntries = parsed }
                    index += 2
                case "--deadline-seconds":
                    if let value, let parsed = Int(value) { deadlineSeconds = parsed }
                    index += 2
                case "--dry-run":
                    dryRun = true
                    index += 1
                default:
                    unknownFlags.append(flag)
                    index += 1
                }
            }
        }

        func validate() throws {
            guard unknownFlags.isEmpty else {
                throw M11RealDirectoryAcceptance.Failure.unknownArgument(unknownFlags.joined(separator: ", "))
            }
            guard sourcePath != nil else {
                throw M11RealDirectoryAcceptance.Failure.missingArgument("--source")
            }
            guard evidenceDirectoryPath != nil else {
                throw M11RealDirectoryAcceptance.Failure.missingArgument("--evidence-dir")
            }
            guard dryRun else { throw M11RealDirectoryAcceptance.Failure.dryRunRequired }
            guard maxEntries > 0 else { throw M11RealDirectoryAcceptance.Failure.invalidMaxEntries }
            guard deadlineSeconds > 0 else { throw M11RealDirectoryAcceptance.Failure.invalidDeadline }
        }
    }

    // MARK: - Output

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
