import Foundation
import FormaCore

/// CLI for the M11 synthetic acceptance (`docs/M11-SYNTHETIC-RUNBOOK.md`).
///
/// Exit codes: 0 = every case passed; 1 = at least one case failed;
/// 3 = nothing failed but at least one case was not verified; 2 = usage or
/// environment error.
@main
struct FormaAcceptanceCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == "m11" else {
            write("usage: FormaAcceptance m11 [--output <path>]\n")
            exit(2)
        }
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

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
