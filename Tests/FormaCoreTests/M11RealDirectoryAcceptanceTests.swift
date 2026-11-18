import Foundation
import Testing
@testable import FormaCore

/// The Level 4 tool: a read-only scan of one authorized directory, the private
/// review sheet it produces, the sanitized summary that may leave the machine,
/// and the human labels that turn a scan into a measured false-exclusion rate.
///
/// Every fixture is synthetic and lives in a temporary directory. No test reads
/// a business directory, writes DEVONthink, calls a provider or enables the
/// eligibility filter.
@Suite("M11 real directory acceptance")
struct M11RealDirectoryAcceptanceTests {

    // MARK: - 1. A normal scan and its decisions

    @Test("a normal scan classifies every discovered record and conserves the counts")
    func normalScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try fixture.write("report", at: "reports/quarterly.pdf")

        let outcome = try await fixture.run()

        #expect(outcome.summary.discovered == 2)
        #expect(outcome.summary.include + outcome.summary.exclude
            + outcome.summary.review + outcome.summary.deferred == outcome.summary.discovered)
        #expect(outcome.summary.coverageState == "COMPLETE")
        #expect(outcome.summary.scanComplete)
        #expect(outcome.summary.probeCoverage.skipped == 0)
        #expect(outcome.summary.probeCoverage.probed == 2)
        #expect(outcome.files[M11RealDirectoryAcceptance.Artifact.sha256Sums] != nil)
        #expect(outcome.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet] != nil)
        #expect(outcome.files[M11RealDirectoryAcceptance.Artifact.sanitizedSummary] != nil)
    }

    // MARK: - 2. Business files inside generated directories

    @Test("business files in build, dist and vendor are never excluded")
    func businessFilesInGeneratedDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("tender", at: "build/tender.pdf")
        try fixture.write("release", at: "dist/release.pdf")
        try fixture.write("datasheet", at: "vendor/datasheet.xlsx")

        let outcome = try await fixture.run()

        #expect(outcome.summary.exclude == 0)
        #expect(outcome.summary.review == 3)
        #expect(outcome.summary.include == 0)
        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue)
        }
    }

    // MARK: - 3. Cache marker and Git protection

    @Test("a verified cache marker does not exclude while a protection fact is unknown")
    func cacheMarkerWithoutKnownProtectionFact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("Signature: 8a477f597d28d172789f06886806bc55\n", at: "cache/CACHEDIR.TAG")
        try fixture.write("artifact", at: "cache/artifact.pdf")

        let outcome = try await fixture.run()

        let row = try #require(outcome.sheet.rows.first { $0.relativePath == "cache/artifact.pdf" })
        #expect(row.decision != EligibilityDecision.exclude.rawValue)
        #expect(row.facts.contains { $0.fact == "cacheMarker" && $0.status == "confirmed" })
    }

    @Test("a tracked file in a cache directory is protected and reviewed")
    func gitTrackedFileInCacheDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("Signature: 8a477f597d28d172789f06886806bc55\n", at: "cache/CACHEDIR.TAG")
        try fixture.write("artifact", at: "cache/artifact.pdf")
        try GitSupport.run(["init", "-q", fixture.source.path])
        try GitSupport.run(["-C", fixture.source.path, "add", "."])
        try GitSupport.run(["-C", fixture.source.path, "commit", "-q", "-m", "fixture"])

        let outcome = try await fixture.run()

        let row = try #require(outcome.sheet.rows.first { $0.relativePath == "cache/artifact.pdf" })
        #expect(row.decision == EligibilityDecision.review.rawValue)
        #expect(row.explanationCode == "git_tracked_protected")
    }

    @Test("technical noise with no protection fact is excluded")
    func technicalNoiseIsExcluded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")

        let outcome = try await fixture.run()

        let row = try #require(outcome.sheet.rows.first { $0.relativePath == "noise/.DS_Store" })
        #expect(row.decision == EligibilityDecision.exclude.rawValue)
        #expect(row.ruleID == "technical-noise-ds-store")
    }

    // MARK: - 4. Unknown facts never exclude

    @Test("an unreadable cache marker and a symlinked repository marker never exclude")
    func unknownFactsNeverExclude() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("not a cache tag\n", at: "cache/CACHEDIR.TAG")
        try fixture.write("artifact", at: "cache/artifact.pdf")
        try fixture.makeDirectory("linked")
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("linked/.git"),
            withDestinationURL: fixture.source.appendingPathComponent(".git"))
        try fixture.write("plan", at: "linked/plan.pdf")

        let outcome = try await fixture.run()

        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue)
        }
        let linked = try #require(outcome.sheet.rows.first { $0.relativePath == "linked/plan.pdf" })
        #expect(linked.facts.contains { $0.fact == "nestedRepository" })
    }

    // MARK: - 5. Permission failure, changed file, partial scan

    @Test("an unreadable subtree is reported as an incomplete scan, not a clean one")
    func unreadableSubtreeDefers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try fixture.write("denied", at: "locked/denied.txt")
        let locked = fixture.source.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        let outcome = try await fixture.run()

        #expect(outcome.summary.scanComplete == false)
        #expect(outcome.summary.coverageState == "PARTIAL")
        #expect(outcome.summary.scanIssueCount >= 1)
        #expect(outcome.summary.unaccounted >= 1)
        // Nothing under the unreadable directory is discovered, so nothing can
        // be excluded because of it.
        for row in outcome.sheet.rows {
            #expect(row.decision != EligibilityDecision.exclude.rawValue)
            #expect(!row.relativePath.hasPrefix("locked/"))
        }
    }

    @Test("a record that changes after the scan is deferred, not decided")
    func changedRecordIsDeferred() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("before", at: "changing.txt")

        let database = fixture.evidence.appendingPathComponent("acceptance-workspace.sqlite")
        try FileManager.default.createDirectory(at: fixture.evidence, withIntermediateDirectories: true)
        let workspace = try SourceWorkspace(databaseURL: database)
        let scope = try await workspace.register(fixture.source)
        let listing = try await workspace.scan(scope)
        try fixture.write("after", at: "changing.txt")

        let probe = try await workspace.probeEligibilityFacts(scope)
        let view = EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing, profile: try MappingProfile.projectArchive(),
            policy: try EligibilityPolicy.shipped(), facts: probe.factsBySource, kind: .measured))
        let row = try #require(view.entries.first)
        #expect(row.decision == EligibilityDecision.defer)
    }

    @Test("a probe limit leaves the remaining records uncovered and says so")
    func probeLimitIsReported() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<5 {
            try fixture.write("file \(index)", at: "file\(index).txt")
        }

        let outcome = try await fixture.run(maxEntries: 2)

        #expect(outcome.summary.probeCoverage.skipped == 3)
        #expect(outcome.summary.coverageState == "PARTIAL")
        #expect(outcome.summary.discovered == 5)
    }

    // MARK: - 6. Source and evidence separation

    @Test("the evidence directory may not be the source, inside it, or around it")
    func evidenceSeparation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        #expect(throws: M11RealDirectoryAcceptance.Failure.evidenceInsideSource) {
            try M11RealDirectoryAcceptance.validate(
                source: fixture.source,
                evidenceDirectory: fixture.source.appendingPathComponent("out"),
                dryRun: true)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.sourceIsEvidence) {
            try M11RealDirectoryAcceptance.validate(
                source: fixture.source, evidenceDirectory: fixture.source, dryRun: true)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.sourceInsideEvidence) {
            try M11RealDirectoryAcceptance.validate(
                source: fixture.source, evidenceDirectory: fixture.base, dryRun: true)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.relativeSourcePath) {
            try M11RealDirectoryAcceptance.absoluteURL(from: "relative/source", kind: .source)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.relativeEvidencePath) {
            try M11RealDirectoryAcceptance.absoluteURL(from: "relative/evidence", kind: .evidenceDirectory)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.relativeLabelPath) {
            try M11RealDirectoryAcceptance.absoluteURL(from: "relative/labels.json", kind: .labels)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.missingSource) {
            try M11RealDirectoryAcceptance.validate(
                source: fixture.base.appendingPathComponent("absent"),
                evidenceDirectory: fixture.evidence, dryRun: true)
        }
        #expect(throws: M11RealDirectoryAcceptance.Failure.dryRunRequired) {
            try M11RealDirectoryAcceptance.validate(
                source: fixture.source, evidenceDirectory: fixture.evidence, dryRun: false)
        }
    }

    // MARK: - 7. Symlinks and the authorized root

    @Test("a symlinked evidence directory cannot reach into the source")
    func symlinkedEvidenceDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("inside")
        let link = fixture.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link,
                                                    withDestinationURL: fixture.source.appendingPathComponent("inside"))

        #expect(throws: M11RealDirectoryAcceptance.Failure.evidenceInsideSource) {
            try M11RealDirectoryAcceptance.validate(
                source: fixture.source, evidenceDirectory: link, dryRun: true)
        }
    }

    @Test("a symlinked source resolves to the directory it points at")
    func symlinkedSourceResolves() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        let link = fixture.base.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)

        let paths = try M11RealDirectoryAcceptance.validate(
            source: link, evidenceDirectory: fixture.evidence, dryRun: true)

        #expect(paths.source.path == fixture.source.resolvingSymlinksInPath().path)
    }

    // MARK: - 8. Empty and unreadable directories

    @Test("an empty directory is a complete scan with nothing in it")
    func emptyDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let outcome = try await fixture.run()

        #expect(outcome.summary.discovered == 0)
        #expect(outcome.summary.coverageState == "COMPLETE")
        #expect(outcome.summary.reviewProgress.state == "not_required")
        #expect(outcome.summary.falseExclusion.state == "N/A")
    }

    @Test("an unreadable source directory never reports a clean scan")
    func unreadableSourceDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.source.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: fixture.source.path)
        }

        do {
            let outcome = try await fixture.run()
            #expect(outcome.summary.coverageState == "PARTIAL")
            #expect(outcome.summary.discovered == 0)
        } catch {
            // A refused root is the other acceptable outcome. What must not
            // happen is a report that claims a complete scan.
        }
    }

    // MARK: - 9. A human KEEP that collides with an exclusion

    @Test("a KEEP label on an excluded record is a measured false exclusion")
    func falseExclusionIsMeasured() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")
        let outcome = try await fixture.run()
        let excluded = try #require(outcome.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })

        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [M11RealDirectoryAcceptance.Label(sourceID: excluded.sourceID,
                                                      label: .keep,
                                                      note: "this is business material")],
            dryRun: true)

        #expect(imported.summary.falseExclusion.state == "MEASURED")
        #expect(imported.summary.falseExclusion.numerator == 1)
        #expect(imported.summary.falseExclusion.denominator == 1)
        #expect(imported.summary.falseExclusion.rate == 1.0)
        #expect(imported.summary.reviewProgress.state == "complete")
        #expect(imported.summary.reviewProgress.keepSamples == 1)
    }

    // MARK: - 10. No labels means no false-exclusion number

    @Test("without labels the false exclusion is not available, not zero")
    func falseExclusionIsNotAvailableWithoutLabels() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")

        let outcome = try await fixture.run()

        #expect(outcome.summary.falseExclusion.state == "N/A")
        #expect(outcome.summary.falseExclusion.numerator == nil)
        #expect(outcome.summary.falseExclusion.denominator == nil)
        #expect(outcome.summary.falseExclusion.rate == nil)
        #expect(outcome.summary.reviewProgress.state == "unreviewed")
        #expect(outcome.summary.reviewProgress.required == 1)
        #expect(outcome.summary.reviewProgress.unreviewed == 1)
    }

    // MARK: - 11. The sanitized summary carries no private path

    @Test("the sanitized summary carries no path and the private sheet does")
    func sanitizedSummaryHasNoPrivatePath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("tender", at: "build/secret-project-name.pdf")

        let outcome = try await fixture.run()
        let summaryURL = try #require(outcome.files[M11RealDirectoryAcceptance.Artifact.sanitizedSummary])
        let text = try String(contentsOf: summaryURL, encoding: .utf8)
        let sheetURL = try #require(outcome.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet])
        let sheetText = try String(contentsOf: sheetURL, encoding: .utf8)

        #expect(!text.contains("secret-project-name"))
        #expect(!text.contains(fixture.source.path))
        #expect(!text.contains("build/"))
        #expect(sheetText.contains("secret-project-name"))
    }

    // MARK: - 12. Repeated runs

    @Test("a repeated run reproduces the sheet and overwrites the evidence safely")
    func repeatedRunIsConsistent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try fixture.write("noise", at: "noise/.DS_Store")
        let before = try fixture.sourceListing()

        let first = try await fixture.run()
        let firstURL = try #require(first.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet])
        let firstSheet = try Data(contentsOf: firstURL)
        let second = try await fixture.run()
        let secondURL = try #require(second.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet])
        let secondSheet = try Data(contentsOf: secondURL)

        #expect(firstSheet == secondSheet)
        #expect(first.summary.evidenceSHA256 == second.summary.evidenceSHA256)
        let after = try fixture.sourceListing()
        #expect(after == before)

        let sumsURL = try #require(second.files[M11RealDirectoryAcceptance.Artifact.sha256Sums])
        let sums = try String(contentsOf: sumsURL, encoding: .utf8)
        let sheetHash = M11RealDirectoryAcceptance.sha256Hex(secondSheet)
        #expect(sums.contains(sheetHash))
        #expect(sums.contains(M11RealDirectoryAcceptance.Artifact.privateReviewSheet))
    }
}

// MARK: - Fixture

private struct Fixture {
    let base: URL
    let source: URL
    let evidence: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forma-m11-real-\(UUID().uuidString)", isDirectory: true)
        source = base.appendingPathComponent("source", isDirectory: true)
        evidence = base.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ text: String, at path: String) throws -> URL {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
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
            source: source, evidenceDirectory: evidence, maxEntries: maxEntries,
            deadlineSeconds: 60, dryRun: true))
    }

    func sourceListing() throws -> [String] {
        let items = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        return items
    }
}

// MARK: - Git

private enum GitSupport {
    static let git = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ arguments: [String]) throws {
        let path = try #require(git)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
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
