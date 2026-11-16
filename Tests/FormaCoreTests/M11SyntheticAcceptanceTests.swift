import Foundation
import Testing

@testable import FormaCore

/// CI self-check for the M11 synthetic acceptance harness.
///
/// This proves the harness itself works on the runner — it does **not** stand
/// in for the on-site run in `docs/M11-SYNTHETIC-RUNBOOK.md`, which must record
/// the host's macOS version, the command and the produced report.
@Suite("M11 synthetic acceptance")
struct M11SyntheticAcceptanceTests {
    @Test("every synthetic case passes on this host")
    func everySyntheticCasePasses() async throws {
        let report = try await M11SyntheticAcceptance.run()
        let failures = report.cases.filter { $0.status == .fail }
        #expect(failures.isEmpty, "failing: \(failures.map { "\($0.id) \($0.detail)" })")
        // A skipped case is not a pass: the runner must actually observe the
        // file system, git and the cache markers it claims to check.
        let skipped = report.cases.filter { $0.status == .notVerified }
        #expect(skipped.isEmpty, "not verified: \(skipped.map { "\($0.id) \($0.detail)" })")
        #expect(report.cases.count >= 20)
        #expect(report.policyDigest.count == 64)
        #expect(report.decisionsDigest.count == 64)
    }
}
