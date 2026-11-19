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

    // MARK: - 12. Repeated runs and evidence ownership

    @Test("a second scan cannot overwrite an evidence set that already holds a review")
    func repeatedScanIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try fixture.write("noise", at: "noise/.DS_Store")
        let before = try fixture.sourceListing()

        let first = try await fixture.run()
        let excluded = try #require(first.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })
        _ = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [M11RealDirectoryAcceptance.Label(sourceID: excluded.sourceID, label: .keep)],
            dryRun: true)
        // The scan itself had no labels, so read the run directory the sheet was
        // written into rather than trusting the first outcome's file list.
        let runDirectory = try #require(
            first.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet]).deletingLastPathComponent()
        let sheetURL = runDirectory.appendingPathComponent(
            M11RealDirectoryAcceptance.Artifact.privateReviewSheet)
        let labelsURL = runDirectory.appendingPathComponent(
            M11RealDirectoryAcceptance.Artifact.humanLabels)
        let sheetBefore = try Data(contentsOf: sheetURL)
        let labelsBefore = try Data(contentsOf: labelsURL)

        await #expect(throws: M11RealDirectoryAcceptance.Failure.evidenceDirectoryNotEmpty) {
            try await fixture.run()
        }

        let sheetAfter = try Data(contentsOf: sheetURL)
        let labelsAfter = try Data(contentsOf: labelsURL)
        #expect(sheetAfter == sheetBefore)
        #expect(labelsAfter == labelsBefore)
        let after = try fixture.sourceListing()
        #expect(after == before)
    }

    @Test("a scan into a new evidence directory produces the same decisions")
    func secondRunDirectoryIsIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try fixture.write("noise", at: "noise/.DS_Store")

        let first = try await fixture.run()
        let second = try await fixture.run(evidenceDirectory: fixture.base.appendingPathComponent("evidence-2"))

        #expect(second.summary.discovered == first.summary.discovered)
        #expect(second.summary.exclude == first.summary.exclude)
        #expect(second.summary.review == first.summary.review)
        #expect(second.summary.include == first.summary.include)
    }

    @Test("an evidence directory that holds a symlink is refused")
    func symlinkedArtifactIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try FileManager.default.createDirectory(at: fixture.evidence, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = fixture.base.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.evidence.appendingPathComponent(M11RealDirectoryAcceptance.Artifact.sanitizedSummary),
            withDestinationURL: target)

        await #expect(throws: M11RealDirectoryAcceptance.Failure.unsafeEvidenceSymlink(
            M11RealDirectoryAcceptance.Artifact.sanitizedSummary)) {
            try await fixture.run()
        }
    }

    @Test("a workspace database that is a symlink is refused")
    func symlinkedDatabaseIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try FileManager.default.createDirectory(at: fixture.evidence, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = fixture.base.appendingPathComponent("outside.sqlite")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.evidence.appendingPathComponent(M11RealDirectoryAcceptance.Artifact.workspaceDatabase),
            withDestinationURL: target)

        await #expect(throws: M11RealDirectoryAcceptance.Failure.unsafeEvidenceSymlink(
            M11RealDirectoryAcceptance.Artifact.workspaceDatabase)) {
            try await fixture.run()
        }
    }

    @Test("an evidence directory other users can reach is refused")
    func unsafeEvidencePermissionsAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try FileManager.default.createDirectory(at: fixture.evidence, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        await #expect(throws: M11RealDirectoryAcceptance.Failure.unsafeEvidencePermissions) {
            try await fixture.run()
        }
    }

    @Test("the private evidence is readable by its owner only")
    func privateEvidenceIsOwnerOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")

        let outcome = try await fixture.run()

        let directory = try #require(outcome.files.values.first?.deletingLastPathComponent())
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let directoryMode = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
        #expect(directoryMode.intValue & 0o077 == 0)
        var privateFiles: [URL] = [directory.appendingPathComponent(
            M11RealDirectoryAcceptance.Artifact.workspaceDatabase)]
        for name in [M11RealDirectoryAcceptance.Artifact.privateReviewSheet,
                     M11RealDirectoryAcceptance.Artifact.sanitizedSummary,
                     M11RealDirectoryAcceptance.Artifact.sha256Sums] {
            privateFiles.append(try #require(outcome.files[name]))
        }
        for url in privateFiles {
            let mode = try #require(
                try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o077 == 0)
        }
    }

    @Test("SHA256SUMS matches the artifacts on disk")
    func sumsMatchArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")

        let outcome = try await fixture.run()
        let sumsURL = try #require(outcome.files[M11RealDirectoryAcceptance.Artifact.sha256Sums])
        let sums = try String(contentsOf: sumsURL, encoding: .utf8)

        var listed = 0
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: "  ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let expected = String(parts[0])
            let name = String(parts[1])
            let url = fixture.evidence.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let data = try Data(contentsOf: url)
            #expect(M11RealDirectoryAcceptance.sha256Hex(data) == expected)
            listed += 1
        }
        #expect(listed == outcome.artifactHashes.count)
    }

    @Test("a label import does not rescan the source directory")
    func labelImportDoesNotScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        try fixture.write("noise", at: "noise/.DS_Store")

        let first = try await fixture.run()
        let excluded = try #require(first.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })
        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [M11RealDirectoryAcceptance.Label(sourceID: excluded.sourceID, label: .keep)],
            dryRun: true)

        #expect(imported.sheet.scanState == first.sheet.scanState)
        #expect(imported.sheet.scanComplete == first.sheet.scanComplete)
        #expect(imported.sheet.probeCoverage == first.sheet.probeCoverage)
        #expect(imported.sheet.rows.map(\.decision) == first.sheet.rows.map(\.decision))
        #expect(imported.sheet.rows.map(\.snapshotFingerprint)
            == first.sheet.rows.map(\.snapshotFingerprint))
    }

    @Test("a label that names another snapshot is refused")
    func labelSnapshotMismatchIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")
        let first = try await fixture.run()
        let excluded = try #require(first.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })

        #expect(throws: M11RealDirectoryAcceptance.Failure.labelSnapshotMismatch) {
            try M11RealDirectoryAcceptance.importLabels(
                source: fixture.source, evidenceDirectory: fixture.evidence,
                labels: [M11RealDirectoryAcceptance.Label(
                    sourceID: excluded.sourceID, label: .keep,
                    snapshotFingerprint: String(repeating: "0", count: 64))],
                dryRun: true)
        }
    }

    @Test("an evidence directory without a review sheet is refused")
    func missingSheetIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.evidence, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        #expect(throws: M11RealDirectoryAcceptance.Failure.sheetMissing) {
            try M11RealDirectoryAcceptance.importLabels(
                source: fixture.source, evidenceDirectory: fixture.evidence,
                labels: [M11RealDirectoryAcceptance.Label(sourceID: UUID(), label: .keep)],
                dryRun: true)
        }
    }

    @Test("a review sheet that cannot be decoded is refused, not treated as absent")
    func corruptSheetIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("notes", at: "notes.txt")
        let outcome = try await fixture.run()
        let sheetURL = try #require(outcome.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet])
        try Data("not a sheet".utf8).write(to: sheetURL)

        #expect(throws: M11RealDirectoryAcceptance.Failure.sheetInvalid) {
            try M11RealDirectoryAcceptance.importLabels(
                source: fixture.source, evidenceDirectory: fixture.evidence,
                labels: [M11RealDirectoryAcceptance.Label(sourceID: UUID(), label: .keep)],
                dryRun: true)
        }
    }

    // MARK: - 13. Census over the excluded set, sample over the included set

    @Test("the excluded census and the included sample stay separate populations")
    func censusAndSampleAreSeparate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")
        try fixture.write("tender text", at: "notes/a.txt")
        try fixture.write("meeting notes", at: "notes/b.txt")
        let outcome = try await fixture.run()
        let excluded = try #require(outcome.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })
        let included = outcome.sheet.rows.filter {
            $0.decision == EligibilityDecision.include.rawValue
        }
        #expect(included.count == 2)

        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [
                M11RealDirectoryAcceptance.Label(sourceID: excluded.sourceID,
                                                 label: .technicalNoise),
                M11RealDirectoryAcceptance.Label(sourceID: included[0].sourceID, label: .keep),
                M11RealDirectoryAcceptance.Label(sourceID: included[1].sourceID, label: .uncertain),
            ],
            dryRun: true)
        let metric = imported.summary.falseExclusion

        // Census: the excluded set was judged record by record, nothing was
        // wrongly excluded inside it.
        let census = try #require(metric.excludeAdjudication)
        #expect(census.state == "CENSUS_COMPLETE")
        #expect(census.excludedRecords == 1)
        #expect(census.adjudicated == 1)
        #expect(census.unadjudicated == 0)
        #expect(census.keepLabelled == 0)
        // Coverage of the review and the safety conclusion are separate fields.
        #expect(census.uncertainLabelled == 0)
        #expect(census.verdict == "SAFE_TO_CLEAR")

        // Sample: two included records were looked at, one kept, one uncertain.
        let sample = try #require(metric.includeSample)
        #expect(sample.state == "SAMPLED")
        #expect(sample.includedRecords == 2)
        #expect(sample.labelled == 2)
        #expect(sample.keepLabelled == 1)
        #expect(sample.uncertainLabelled == 1)
        #expect(sample.technicalNoiseLabelled == 0)

        // The labelled arithmetic keeps its documented meaning and its own
        // denominator; it is not the census and not the sample.
        #expect(metric.state == "MEASURED")
        #expect(metric.numerator == 0)
        #expect(metric.denominator == 1)
        #expect(metric.population == "human-labelled KEEP records")

        // The artifact refuses to let the sample be read as a population rate.
        let boundary = try #require(metric.claimBoundary)
        #expect(boundary.contains("every excluded record was adjudicated"))
        #expect(boundary.contains("does not measure the false-exclusion rate"))
        #expect(imported.summary.reviewProgress.includeSampled == 2)
    }

    @Test("an excluded record without a verdict leaves the census incomplete")
    func censusIsIncompleteUntilEveryExclusionIsAdjudicated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "one/.DS_Store")
        try fixture.write("noise", at: "two/.DS_Store")
        let outcome = try await fixture.run()
        let excluded = outcome.sheet.rows.filter {
            $0.decision == EligibilityDecision.exclude.rawValue
        }
        #expect(excluded.count == 2)

        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [M11RealDirectoryAcceptance.Label(sourceID: excluded[0].sourceID,
                                                      label: .technicalNoise)],
            dryRun: true)
        let census = try #require(imported.summary.falseExclusion.excludeAdjudication)
        #expect(census.state == "CENSUS_INCOMPLETE")
        #expect(census.excludedRecords == 2)
        #expect(census.adjudicated == 1)
        #expect(census.unadjudicated == 1)
        #expect(census.keepLabelled == 0)
        #expect(census.uncertainLabelled == 0)
        #expect(census.verdict == "INCOMPLETE")
        // No KEEP label at all: the arithmetic stays N/A even though the census
        // has a verdict, because "zero observed" is not "measured zero".
        #expect(imported.summary.falseExclusion.state == "N/A")
        #expect(imported.summary.reviewProgress.state == "in_progress")
        let boundary = try #require(imported.summary.falseExclusion.claimBoundary)
        #expect(boundary.contains("not fully evidenced"))
    }

    @Test("a KEEP inside the excluded set is an observed false exclusion in the census")
    func observedFalseExclusionLandsInTheCensus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")
        let outcome = try await fixture.run()
        let excluded = try #require(outcome.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })

        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [M11RealDirectoryAcceptance.Label(sourceID: excluded.sourceID, label: .keep)],
            dryRun: true)
        let census = try #require(imported.summary.falseExclusion.excludeAdjudication)
        #expect(census.state == "CENSUS_COMPLETE")
        #expect(census.keepLabelled == 1)
        #expect(census.verdict == "FALSE_EXCLUSION_FOUND")
        #expect(imported.summary.falseExclusion.numerator == 1)
        #expect(imported.summary.falseExclusion.rate == 1.0)
        // The sample side is untouched by an exclusion finding: this fixture has
        // no included record at all, so the sample is `N/A` rather than
        // `NOT_SAMPLED` — "nothing to sample" is not "sampling was skipped".
        let sample = try #require(imported.summary.falseExclusion.includeSample)
        #expect(sample.state == "N/A")
        #expect(sample.labelled == 0)
    }

    @Test("an UNCERTAIN verdict is neither a KEEP nor a confirmed error")
    func uncertainIsNeitherKeepNorError() async throws {
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
                                                      label: .uncertain,
                                                      note: "用途不明")],
            dryRun: true)
        let census = try #require(imported.summary.falseExclusion.excludeAdjudication)
        // The reviewer did judge it, so the census is complete...
        #expect(census.adjudicated == 1)
        #expect(census.state == "CENSUS_COMPLETE")
        // ...but an unresolved record is not evidence of a false exclusion,
        // and it is never counted as a KEEP.
        #expect(census.keepLabelled == 0)
        #expect(imported.summary.falseExclusion.state == "N/A")
        #expect(imported.summary.reviewProgress.uncertainSamples == 1)
        #expect(imported.summary.reviewProgress.keepSamples == 0)
        // Judged, but unresolved: the census is complete and the exclusion set is
        // still not cleared.
        #expect(census.uncertainLabelled == 1)
        #expect(census.verdict == "NEEDS_REVIEW")
        let boundary = try #require(imported.summary.falseExclusion.claimBoundary)
        #expect(boundary.contains("not cleared"))
        #expect(imported.sheet.rows.first { $0.sourceID == excluded.sourceID }?.humanLabel
                == M11RealDirectoryAcceptance.HumanLabel.uncertain)
    }

    @Test("a census of confirmed noise is the only state that clears the exclusion")
    func completeNoiseCensusIsSafeToClear() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "one/.DS_Store")
        try fixture.write("noise", at: "two/._report.pdf")
        let outcome = try await fixture.run()
        let excluded = outcome.sheet.rows.filter {
            $0.decision == EligibilityDecision.exclude.rawValue
        }
        #expect(excluded.count == 2)

        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: excluded.map {
                M11RealDirectoryAcceptance.Label(sourceID: $0.sourceID, label: .technicalNoise)
            },
            dryRun: true)
        let census = try #require(imported.summary.falseExclusion.excludeAdjudication)
        #expect(census.state == "CENSUS_COMPLETE")
        #expect(census.keepLabelled == 0)
        #expect(census.uncertainLabelled == 0)
        #expect(census.verdict == "SAFE_TO_CLEAR")
        let boundary = try #require(imported.summary.falseExclusion.claimBoundary)
        #expect(boundary.contains("adjudicated as technical noise"))
    }

    @Test("a run with nothing included reports an N/A sample, not an empty one")
    func noIncludedRecordsMeansNotApplicable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")

        let outcome = try await fixture.run()

        #expect(outcome.summary.include == 0)
        let sample = try #require(outcome.summary.falseExclusion.includeSample)
        #expect(sample.state == "N/A")
        #expect(sample.includedRecords == 0)
        #expect(sample.labelled == 0)
        let boundary = try #require(outcome.summary.falseExclusion.claimBoundary)
        #expect(boundary.contains("no included records to sample"))
    }

    @Test("a complete census with an unjudged REVIEW record is not a finished review")
    func unjudgedReviewRecordKeepsTheRunOpen() async throws {
        // The census only ever covers EXCLUDE. A run whose exclusions are all
        // adjudicated still has an unjudged REVIEW record here, so the review
        // progress is `in_progress` while `CENSUS_COMPLETE` holds. Runbook §5
        // classifies that combination as PARTIAL; this test pins the inputs that
        // make the distinction necessary.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")
        try fixture.write("artifact", at: "build/output.bin")

        let outcome = try await fixture.run()
        let excluded = outcome.sheet.rows.filter {
            $0.decision == EligibilityDecision.exclude.rawValue
        }
        let reviewed = outcome.sheet.rows.filter {
            $0.decision == EligibilityDecision.review.rawValue
        }
        #expect(excluded.count == 1)
        #expect(reviewed.count == 1)

        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [M11RealDirectoryAcceptance.Label(sourceID: excluded[0].sourceID,
                                                      label: .technicalNoise)],
            dryRun: true)
        let census = try #require(imported.summary.falseExclusion.excludeAdjudication)
        #expect(census.state == "CENSUS_COMPLETE")
        #expect(census.verdict == "SAFE_TO_CLEAR")
        #expect(imported.summary.reviewProgress.state == "in_progress")
        #expect(imported.summary.reviewProgress.required == 2)
        #expect(imported.summary.reviewProgress.reviewed == 1)
    }

    @Test("artifacts written before the census/sample split still decode")
    func preSplitArtifactsStillDecode() throws {
        let preSplit = Data("""
        {
          "schema_version": "1.0",
          "coverage_state": "COMPLETE",
          "state": "MEASURED",
          "numerator": 0,
          "denominator": 14,
          "rate": 0.0,
          "unit": "records",
          "population": "human-labelled KEEP records",
          "review_progress": {
            "state": "complete", "required": 37, "reviewed": 37, "unreviewed": 0,
            "keep_samples": 14, "technical_noise_samples": 37, "uncertain_samples": 7
          }
        }
        """.utf8)
        let report = try JSONDecoder().decode(
            M11RealDirectoryAcceptance.FalseExclusionReport.self, from: preSplit)
        #expect(report.denominator == 14)
        #expect(report.excludeAdjudication == nil)
        #expect(report.includeSample == nil)
        #expect(report.claimBoundary == nil)
        #expect(report.reviewProgress.includeSampled == nil)

        let roundTrip = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(
            M11RealDirectoryAcceptance.FalseExclusionReport.self, from: roundTrip) == report)
    }

    @Test("the new statistics fields leak no path or file name")
    func statisticsFieldsStaySanitized() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("noise", at: "noise/.DS_Store")
        try fixture.write("tender text", at: "notes/a.txt")
        let outcome = try await fixture.run()
        let excluded = try #require(outcome.sheet.rows.first {
            $0.decision == EligibilityDecision.exclude.rawValue
        })
        let included = try #require(outcome.sheet.rows.first {
            $0.decision == EligibilityDecision.include.rawValue
        })
        let imported = try M11RealDirectoryAcceptance.importLabels(
            source: fixture.source, evidenceDirectory: fixture.evidence,
            labels: [
                M11RealDirectoryAcceptance.Label(sourceID: excluded.sourceID, label: .technicalNoise),
                M11RealDirectoryAcceptance.Label(sourceID: included.sourceID, label: .keep),
            ],
            dryRun: true)

        let data = try JSONEncoder().encode(imported.summary)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(fixture.base.path))
        #expect(!text.contains(fixture.source.path))
        #expect(!text.contains(".DS_Store"))
        #expect(!text.contains("notes"))
        // Relative paths belong to the private sheet only. They are matched on
        // the decoded row: JSON text escapes "/", so a raw substring check on
        // the file is not a reliable way to read a path back.
        let sheetURL = try #require(
            imported.files[M11RealDirectoryAcceptance.Artifact.privateReviewSheet])
        let sheetData = try Data(contentsOf: sheetURL)
        #expect(imported.sheet.rows.contains { $0.relativePath == "noise/.DS_Store" })
        let decoded = try FormaJSON.decode(M11RealDirectoryAcceptance.PrivateReviewSheet.self,
                                           from: sheetData)
        #expect(decoded.rows.map(\.relativePath) == imported.sheet.rows.map(\.relativePath))
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

    func run(maxEntries: Int = 5_000,
             evidenceDirectory: URL? = nil) async throws -> M11RealDirectoryAcceptance.Outcome {
        try await M11RealDirectoryAcceptance.run(M11RealDirectoryAcceptance.Request(
            source: source, evidenceDirectory: evidenceDirectory ?? evidence,
            maxEntries: maxEntries, deadlineSeconds: 60, dryRun: true))
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
