import Foundation
import Testing

@testable import FormaCore

/// Protection-rule regressions executed through the real-directory acceptance
/// path, on real filesystems, in a temporary directory the test owns.
///
/// What this suite pins (Level 4 closure, work package B):
///   * nothing escapes the authorized root, and a symlink out of it is never
///     walked into;
///   * a protection rule never reaches a neighbouring business record;
///   * the four-state counts always conserve over what was actually probed;
///   * an unknown or unreadable fact never becomes a silent `EXCLUDE`;
///   * the scan leaves the source tree byte-for-byte and metadata-for-metadata
///     alone.
///
/// Deliberately *not* done here: no test fakes a dataless record by reading a
/// file's content, and no test asserts a rule `eligibility.v2` does not contain.
/// Filesystem-dependent name behaviour (Unicode normalisation, case folding) is
/// asserted as an invariant, not as a fixed count, because APFS and ext4 differ.
/// `SF_DATALESS` cannot be set from a fixture on either platform, so dataless
/// stays covered at the classifier level (`ImportEligibilityTests`
/// `a dataless OneDrive file...`, `hydration pending...`) and as a Mac-only
/// pending item (Issue #129). Timeout and cancellation coverage stays in
/// `EligibilityProbeTests` (`a deadline...`, `a cancelled probe...`).
@Suite("M11 protection regressions")
struct M11ProtectionRegressionTests {

    // MARK: - 1. An exclusion stays local to the record that matched

    @Test("an excluded noise file never reaches its siblings")
    func noiseExclusionStaysLocal() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("junk", at: "proj/.DS_Store")
        try fixture.write("tender", at: "proj/report.pdf")
        try fixture.write("minutes", at: "proj/notes.docx")
        try fixture.write("junk", at: "proj/sub/.DS_Store")

        let outcome = try await fixture.run()

        #expect(row(outcome, "proj/.DS_Store")?.decision == EligibilityDecision.exclude.rawValue)
        #expect(row(outcome, "proj/sub/.DS_Store")?.decision == EligibilityDecision.exclude.rawValue)
        #expect(row(outcome, "proj/report.pdf")?.decision == EligibilityDecision.include.rawValue)
        #expect(row(outcome, "proj/notes.docx")?.decision == EligibilityDecision.include.rawValue)
        #expect(outcome.summary.exclude == 2)
        fixture.expectConserved(outcome)
    }

    @Test("a real .git repository never excludes anything inside itself")
    func gitDirectoryNeverExcludes() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("readme", at: "README.md")
        try fixture.write("spec", at: "docs/spec.docx")
        try GitRepo.run(["init", "-q", fixture.source.path])
        try GitRepo.run(["-C", fixture.source.path, "add", "."])
        try GitRepo.run(["-C", fixture.source.path, "commit", "-q", "-m", "fixture"])

        let outcome = try await fixture.run()

        // Repository content is discovered and reviewed, never dropped.
        #expect(outcome.sheet.rows.contains { $0.relativePath.hasPrefix(".git/") })
        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue,
                    "unexpected EXCLUDE for \(row.relativePath)")
        }
        let readme = try #require(row(outcome, "README.md"))
        #expect(readme.facts.contains { $0.fact == "gitTracked" })
        fixture.expectConserved(outcome)
    }

    @Test("a verified cache marker does not spread to adjacent directories")
    func cacheMarkerDoesNotSpread() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("Signature: 8a477f597d28d172789f06886806bc55\n", at: "cache/CACHEDIR.TAG")
        try fixture.write("blob", at: "cache/artifact.bin")
        try fixture.write("tender", at: "cache-2/keep.pdf")
        try fixture.write("manual", at: "cached-docs/manual.pdf")

        let outcome = try await fixture.run()

        // Neighbours whose names merely look similar are untouched.
        #expect(row(outcome, "cache-2/keep.pdf")?.decision == EligibilityDecision.include.rawValue)
        #expect(row(outcome, "cached-docs/manual.pdf")?.decision == EligibilityDecision.include.rawValue)
        // Inside the marked directory the exclusion needs known protecting
        // facts; without them the record is reviewed, never silently excluded.
        let artifact = try #require(row(outcome, "cache/artifact.bin"))
        #expect(artifact.decision != EligibilityDecision.exclude.rawValue)
        #expect(artifact.explanationCode == "protection_fact_unknown")
        fixture.expectConserved(outcome)
    }

    // MARK: - 2. The authorized root is the boundary

    @Test("a symlink out of the root is never walked into")
    func symlinkEscapeIsNotWalked() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.writeInto(outside, named: "secret.pdf", text: "private")
        let outsideBefore = try ProtectionFixture.digests(of: outside)

        try fixture.write("plan", at: "keep/plan.pdf")
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("escape"), withDestinationURL: outside)

        let outcome = try await fixture.run()

        // Nothing from outside the root became a record.
        #expect(!outcome.sheet.rows.contains { $0.relativePath.hasPrefix("escape/") })
        #expect(!outcome.sheet.rows.contains { $0.relativePath.contains("secret.pdf") })
        // The link itself is a record, and an unknown kind is never excluded.
        let link = try #require(row(outcome, "escape"))
        #expect(link.decision != EligibilityDecision.exclude.rawValue)
        // The outside directory was not read either.
        #expect(try ProtectionFixture.digests(of: outside) == outsideBefore)
        fixture.expectConserved(outcome)
    }

    @Test("a symlink cycle terminates and still conserves")
    func symlinkCycleTerminates() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("real", at: "docs/real.pdf")
        let a = fixture.source.appendingPathComponent("loop-a")
        let b = fixture.source.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

        let outcome = try await fixture.run()

        let loops = outcome.sheet.rows.filter { $0.relativePath.hasPrefix("loop-") }
        #expect(loops.count == 2)
        for entry in loops {
            #expect(entry.decision != EligibilityDecision.exclude.rawValue)
        }
        fixture.expectConserved(outcome)
    }

    // MARK: - 3. Unknown and unreadable never become silent exclusions

    @Test("an unreadable file is not excluded and the tree still conserves")
    func unreadableFileIsNotExcluded() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.restorePermissions() }
        defer { fixture.cleanUp() }
        try fixture.write("tender", at: "locked/report.pdf")
        try fixture.write("ok", at: "open/notes.txt")
        let target = fixture.source.appendingPathComponent("locked/report.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)

        let outcome = try await fixture.run()

        #expect(row(outcome, "locked/report.pdf") != nil)
        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue,
                    "an unreadable or unknown record must never be silently excluded")
        }
        fixture.expectConserved(outcome)
    }

    @Test("an unreadable directory is reported, not quietly dropped")
    func unreadableDirectoryIsReported() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.restorePermissions() }
        defer { fixture.cleanUp() }
        try fixture.write("no", at: "locked/secret.txt")
        try fixture.write("yes", at: "open/notes.txt")
        let denied = fixture.source.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

        let outcome = try await fixture.run()

        // The subtree cannot be listed, so the scan is not complete and nothing
        // inside it is claimed as excluded.
        #expect(outcome.summary.scanComplete == false)
        #expect(outcome.summary.coverageState == "PARTIAL")
        #expect(outcome.summary.exclude == 0)
        #expect(outcome.summary.scanIssueCount > 0)
        #expect(outcome.completeness.scanIssueCount == outcome.summary.scanIssueCount)
        fixture.expectConserved(outcome)
    }

    @Test("empty directories and hidden trees invent no exclusions")
    func emptyAndHiddenStayInnocent() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("empty")
        try fixture.makeDirectory("deep/empty/inner")
        try fixture.write("hidden note", at: ".hidden/config.txt")
        try fixture.write("dot dir", at: ".cache/state.bin")
        try fixture.write("visible", at: "visible.txt")

        let outcome = try await fixture.run()

        // Directories are not records, so an empty tree cannot exclude anything.
        #expect(outcome.summary.discovered == outcome.sheet.rows.count)
        #expect(outcome.summary.exclude == 0)
        #expect(outcome.summary.coverageState == "COMPLETE")
        // Hidden files are ordinary records: the policy has no hidden-file rule.
        #expect(row(outcome, ".hidden/config.txt")?.decision == EligibilityDecision.include.rawValue)
        #expect(row(outcome, ".cache/state.bin")?.decision == EligibilityDecision.include.rawValue)
        fixture.expectConserved(outcome)
    }

    // MARK: - 4. Name boundaries

    @Test("equivalent Unicode names are reported once each, without loss")
    func unicodeNamesStayConsistent() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        // "café.txt" in composed and decomposed form. APFS folds them into one
        // stored file; a normalization-sensitive volume keeps two.
        try fixture.write("nfc", at: "café.txt")
        try fixture.write("nfd", at: "café.txt")
        try fixture.write("plain", at: "plain.txt")

        let outcome = try await fixture.run()
        let paths = outcome.sheet.rows.map(\.relativePath)
        #expect(Set(paths).count == paths.count, "one record per stored name")
        // Every record names a file that really exists, and every stored file is
        // either a record or accounted for by a reported scan issue.
        try expectStoredMatchesRecords(outcome, fixture: fixture)
        #expect(paths.contains("plain.txt"))
        fixture.expectConserved(outcome)
    }

    @Test("a case-only name pair is never merged into an exclusion")
    func caseOnlyNamesAreNeverMerged() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("upper", at: "Report.pdf")
        try fixture.write("lower", at: "report.pdf")

        let outcome = try await fixture.run()

        let paths = outcome.sheet.rows.map(\.relativePath)
        #expect(Set(paths).count == paths.count)
        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue)
        }
        try expectStoredMatchesRecords(outcome, fixture: fixture)
        fixture.expectConserved(outcome)
    }

    // MARK: - 5. Diagnostic-looking extensions

    @Test("log, ini and csv are never excluded by their extension")
    func diagnosticExtensionsAreNotExcluded() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("runtime", at: "onekeylog/app.log")
        try fixture.write("config", at: "onekeylog/settings.ini")
        try fixture.write("records", at: "onekeylog/records.csv")
        try fixture.write("acceptance", at: "deliverables/report-acceptance.csv")
        try fixture.write("ops", at: "ops/2026-11-19.log")

        let outcome = try await fixture.run()

        // `eligibility.v2` has no extension-based exclusion at all, so none of
        // these can be dropped. If a future rule changes that, this test is the
        // regression that forces it through review (Issue #131).
        #expect(outcome.summary.discovered == 5)
        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue,
                    "unexpected EXCLUDE for \(row.relativePath)")
        }
        fixture.expectConserved(outcome)
    }

    // MARK: - 6. Coverage honesty

    @Test("records above the probe budget are skipped, never reported as verified")
    func probeBudgetIsHonest() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        for index in 0..<6 {
            try fixture.write("body", at: "docs/file\(index).pdf")
        }

        let outcome = try await fixture.run(maxEntries: 2)

        #expect(outcome.summary.coverageState == "PARTIAL")
        #expect(outcome.summary.probeCoverage.discovered == 6)
        #expect(outcome.summary.probeCoverage.probed == 2)
        #expect(outcome.summary.probeCoverage.skipped == 4)
        // What the tool actually does with records the budget never reached,
        // asserted as it behaves rather than as one might wish:
        //
        //   * they are still rows in the private review sheet, so nothing
        //     disappears from human review;
        //   * they carry no facts, and a record with unknown facts can never be
        //     excluded, so `exclude` stays 0;
        //   * they land on `default-mapping-candidate`, which means the
        //     `include` count mixes probed candidates with unprobed ones. The
        //     per-row provenance and `probe_coverage.skipped` are the only place
        //     that distinction survives, and the run is `PARTIAL` because of it.
        //     Reported to the Owner as a candidate Issue; not fixed here, because
        //     turning it into `DEFER` would change what `by_decision` means for
        //     every historical artifact.
        #expect(outcome.sheet.rows.count == 6)
        #expect(outcome.summary.exclude == 0)
        #expect(outcome.summary.include == 6)
        fixture.expectConserved(outcome)
    }

    @Test("a clean run reports no unaccounted path and no scan issue")
    func completeRunHasNoUnaccountedPaths() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.cleanUp() }
        try fixture.write("tender", at: "docs/tender.pdf")

        let outcome = try await fixture.run()

        #expect(outcome.summary.unaccounted == 0)
        #expect(outcome.summary.scanIssueCount == 0)
        #expect(outcome.sheet.unaccountedPaths.isEmpty)
        #expect(outcome.completeness.perDecision[EligibilityDecision.include.rawValue] == 1)
        fixture.expectConserved(outcome)
    }

    // MARK: - 7. The source tree is never touched

    @Test("the scan changes no content, no metadata and no name in the source")
    func scanLeavesSourceUntouched() async throws {
        let fixture = try ProtectionFixture()
        defer { fixture.restorePermissions() }
        defer { fixture.cleanUp() }
        try fixture.write("Signature: 8a477f597d28d172789f06886806bc55\n", at: "cache/CACHEDIR.TAG")
        try fixture.write("blob", at: "cache/artifact.bin")
        try fixture.write("junk", at: "proj/.DS_Store")
        try fixture.write("tender", at: "proj/report.pdf")
        try fixture.write("appledouble", at: "proj/._report.pdf")
        try fixture.write("runtime", at: "onekeylog/app.log")
        try fixture.makeDirectory("empty")
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("link.pdf"),
            withDestinationURL: fixture.source.appendingPathComponent("proj/report.pdf"))
        try fixture.write("no", at: "locked/secret.txt")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.source.appendingPathComponent("locked").path)

        let before = try ProtectionFixture.digests(of: fixture.source)
        #expect(before.count > 8)

        let outcome = try await fixture.run()

        // Same names, same bytes, same size, same mode, same modification time.
        #expect(try ProtectionFixture.digests(of: fixture.source) == before)
        // No artifact was written inside the source tree.
        for file in outcome.files.values {
            #expect(!file.path.hasPrefix(fixture.source.path + "/"))
        }
        fixture.expectConserved(outcome)
    }

    // MARK: - Assertions shared by the scenarios

    private func row(_ outcome: M11RealDirectoryAcceptance.Outcome,
                     _ path: String) -> M11RealDirectoryAcceptance.ReviewRow? {
        outcome.sheet.rows.first { $0.relativePath == path }
    }

    /// Records and stored files must agree, allowing for the two ways a name can
    /// legitimately disappear: a case- or normalization-insensitive volume that
    /// stores one file where two spellings were written, and a subtree the scan
    /// could not read. The second must show up as a scan issue, never as silence.
    private func expectStoredMatchesRecords(
        _ outcome: M11RealDirectoryAcceptance.Outcome, fixture: ProtectionFixture) throws {
        let stored = Set(try ProtectionFixture.files(under: fixture.source))
        let recorded = Set(outcome.sheet.rows.map(\.relativePath))
        #expect(recorded.isSubset(of: stored), "a record must name a file that exists")
        let unrecorded = stored.subtracting(recorded)
        if !unrecorded.isEmpty {
            #expect(outcome.summary.scanIssueCount > 0
                    || outcome.summary.discovered < stored.count,
                    "a stored file that produced no record needs a reported reason")
        }
    }
}

// MARK: - Fixture

private struct ProtectionFixture {
    let base: URL
    let source: URL
    let evidence: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forma-m11-protection-\(UUID().uuidString)", isDirectory: true)
        source = base.appendingPathComponent("source", isDirectory: true)
        evidence = base.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func cleanUp() {
        restorePermissions()
        try? FileManager.default.removeItem(at: base)
    }

    /// Permission-restricted fixtures have to be opened again before removal:
    /// directories need the execute bit, files only ever need to be deletable.
    func restorePermissions() {
        let manager = FileManager.default
        for directory in [source, source.appendingPathComponent("locked")] {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        for path in ["locked/report.pdf", "locked/secret.txt"] {
            try? manager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: source.appendingPathComponent(path).path)
        }
    }

    @discardableResult
    func write(_ text: String, at path: String) throws -> URL {
        try writeInto(source.appendingPathComponent(path).deletingLastPathComponent(),
                      named: (path as NSString).lastPathComponent, text: text)
    }

    /// Creates the parent directories first, so a file can be written into a
    /// path that does not exist yet.
    @discardableResult
    func writeInto(_ directory: URL, named name: String, text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    func makeDirectory(_ path: String) throws -> URL {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func run(maxEntries: Int = 5_000) async throws -> M11RealDirectoryAcceptance.Outcome {
        try await M11RealDirectoryAcceptance.run(M11RealDirectoryAcceptance.Request(
            source: source, evidenceDirectory: evidence,
            maxEntries: maxEntries, deadlineSeconds: 60, dryRun: true))
    }

    /// Conservation over *discovered* records, not over probed ones. The CI run
    /// of the first draft pinned the difference down: a record the probe budget
    /// never reached still appears in the private review sheet and is counted in
    /// the four-state summary — as `DEFER`. That is the honest shape (nothing
    /// vanishes from the human review sheet), and it is what the identity
    /// `include + exclude + review + defer == discovered` states, the same one
    /// `EligibilitySummary.isConserved` uses. `probed + skipped == discovered`
    /// is reported separately, so "not verified" is never read as "verified".
    func expectConserved(_ outcome: M11RealDirectoryAcceptance.Outcome) {
        let summary = outcome.summary
        #expect(summary.include + summary.exclude + summary.review + summary.deferred
            == summary.discovered)
        #expect(summary.probeCoverage.probed + summary.probeCoverage.skipped
            == summary.probeCoverage.discovered)
        #expect(summary.discovered == summary.probeCoverage.discovered)
        let paths = outcome.sheet.rows.map(\.relativePath)
        #expect(Set(paths).count == paths.count)
        #expect(paths.count == summary.discovered)
        for path in paths {
            #expect(!path.hasPrefix("/"))
            #expect(!path.split(separator: "/").contains(".."))
        }
    }

    /// Every entry below `root`, keyed by relative path. Symlinks are recorded
    /// as links and never followed, so taking a snapshot cannot materialize or
    /// resolve anything. Paths that cannot be read are marked as such instead of
    /// failing the whole walk.
    static func digests(of root: URL) throws -> [String: String] {
        var found: [String: String] = [:]
        try walk(root, relative: "", into: &found)
        return found
    }

    /// The regular files the filesystem actually stores, for normalization
    /// comparisons. Directories and symlinks are excluded: they are not records.
    static func files(under root: URL) throws -> [String] {
        try digests(of: root).filter { $0.value.hasPrefix("file") }.keys.sorted()
    }

    private static func walk(_ directory: URL, relative: String,
                             into found: inout [String: String]) throws {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(atPath: directory.path) else {
            found[relative.isEmpty ? "." : relative] = "directory-unreadable"
            return
        }
        for child in children.sorted() {
            let childURL = directory.appendingPathComponent(child)
            let path = relative.isEmpty ? child : "\(relative)/\(child)"
            guard let attributes = try? manager.attributesOfItem(atPath: childURL.path) else {
                found[path] = "stat-failed"
                continue
            }
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                found[path] = "symlink"
            case .typeDirectory:
                found[path] = "directory"
                try walk(childURL, relative: path, into: &found)
            default:
                guard let data = try? Data(contentsOf: childURL) else {
                    found[path] = "file-unreadable"
                    break
                }
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
                let modified = (attributes[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? -1
                found[path] = "file size=\(data.count) mode=\(String(format: "%o", mode)) "
                    + "mtime=\(String(format: "%.6f", modified)) "
                    + "sha256=\(M11RealDirectoryAcceptance.sha256Hex(data))"
            }
        }
    }
}

private enum GitRepo {
    static let path = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ arguments: [String]) throws {
        let executable = try #require(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_NAME"] = "Fixture"
        environment["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Fixture"
        environment["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0,
                     "git \(arguments.joined(separator: " ")) failed")
    }
}
