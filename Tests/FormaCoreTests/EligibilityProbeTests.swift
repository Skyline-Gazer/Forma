import Foundation
import Testing
@testable import FormaCore

/// The read-only eligibility fact probe: what it establishes, what it refuses to
/// establish, and the metadata-mutation and time-outs it reports instead of
/// guessing.
///
/// Every fixture is synthetic and every write stays inside a temporary directory.
/// The probe itself is asserted to create nothing.
@Suite("Eligibility fact probe")
struct EligibilityProbeTests {
    // MARK: - Fixtures

    private struct Fixture {
        let base: URL
        let root: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            root = base.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: base) }

        @discardableResult
        func write(_ data: Data, at path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        @discardableResult
        func write(_ text: String, at path: String) throws -> URL {
            try write(Data(text.utf8), at: path)
        }

        @discardableResult
        func makeDirectory(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func entry(_ path: String, size: Int64? = nil, mtime: Int64? = nil) throws -> SourceEntry {
            let url = root.appendingPathComponent(path)
            let metadata = try SourceFileMetadata.read(url)
            return SourceEntry(id: UUID(), rootID: UUID(), relativePath: path,
                               normalizedRelativePath: path.lowercased(), state: .present,
                               hydrationPending: false, sourceVersion: 1, snapshotRevision: 1,
                               provider: .local, snapshotFingerprint: String(repeating: "c", count: 64),
                               sizeBytes: size ?? metadata.sizeBytes,
                               modificationTimeNanoseconds: mtime ?? metadata.modifiedNanoseconds,
                               sha256: nil)
        }

        func probe(_ entries: [SourceEntry], request: EligibilityProbeRequest = .init(),
                   caller: [UUID: EligibilityFacts] = [:]) throws -> EligibilityProbeReport {
            let access = try SourceRootAccess(root)
            return EligibilityFactCollector.collect(access: access, entries: entries,
                                                    request: request, callerFacts: caller)
        }
    }

    private let marker = "Signature: 8a477f597d28d172789f06886806bc55\n"

    // MARK: - Cache marker

    @Test("a standard CACHEDIR.TAG is verified from an ancestor directory")
    func verifiedMarker() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write(marker, at: "CACHEDIR.TAG")
        try fixture.write("payload", at: "cache/deep/blob.bin")
        let entry = try fixture.entry("cache/deep/blob.bin")

        let report = try fixture.probe([entry], request: .init(includeGit: false))
        let result = try #require(report.results.first)

        #expect(result.facts.cacheMarker == .verifiedSignature)
        #expect(result.facts.entry.relativePath == "cache/deep/blob.bin")
        #expect(result.provenance(for: "cacheMarker")?.status == .confirmed)
        #expect(result.provenance(for: "cacheMarker")?.evidence?.isEmpty == false)
        #expect(result.provenance(for: "cacheMarker")?.evidence?.contains("cache") == false)
    }

    @Test("a marker without the standard signature is present but unverified")
    func invalidMarker() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("this is not a tag", at: "CACHEDIR.TAG")
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.cacheMarker == .presentUnverified)
        #expect(result.provenance(for: "cacheMarker")?.status == .failed)
        #expect(result.provenance(for: "cacheMarker")?.reason == "marker_signature_invalid")
    }

    @Test("a symlinked marker is unreadable, never followed")
    func symlinkedMarker() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let target = try fixture.write(marker, at: "elsewhere/tag")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("CACHEDIR.TAG"),
                                                   withDestinationURL: target)
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.cacheMarker == .unreadable)
        #expect(result.provenance(for: "cacheMarker")?.reason == "symlink")
    }

    @Test("an oversized marker is not read into memory")
    func oversizedMarker() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write(marker + String(repeating: "x", count: 8_192), at: "CACHEDIR.TAG")
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.cacheMarker == .unreadable)
        #expect(result.provenance(for: "cacheMarker")?.reason == "oversized")
    }

    // MARK: - Nested repositories

    @Test("a nested .git directory is reported, and protects the file")
    func nestedRepository() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.makeDirectory("Project/.git")
        try fixture.write("payload", at: "Project/blob.bin")
        let entry = try fixture.entry("Project/blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.nestedRepository == .yes)
        #expect(result.provenance(for: "nestedRepository")?.status == .confirmed)
    }

    @Test("a scope without a nested repository reports a confirmed no")
    func noNestedRepository() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "Project/blob.bin")
        let entry = try fixture.entry("Project/blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.nestedRepository == .no)
        #expect(result.provenance(for: "nestedRepository")?.status == .confirmed)
    }

    @Test("a .git file pointing outside the authorized root is unknown, not followed")
    func gitdirOutsideRoot() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try fixture.write("gitdir: \(outside.path)\n", at: "Project/.git")
        try fixture.write("payload", at: "Project/blob.bin")
        let entry = try fixture.entry("Project/blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.nestedRepository == .unknown)
        #expect(result.provenance(for: "nestedRepository")?.status == .outsideAuthorization)
        #expect(result.provenance(for: "nestedRepository")?.reason == "gitdir_outside_authorization")
    }

    @Test("a symlinked .git is unknown, never followed")
    func symlinkedGitMarker() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.makeDirectory("Project/target")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Project/.git"),
                                                   withDestinationURL: fixture.root.appendingPathComponent("Project/target"))
        try fixture.write("payload", at: "Project/blob.bin")
        let entry = try fixture.entry("Project/blob.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.nestedRepository == .unknown)
        #expect(result.provenance(for: "nestedRepository")?.reason == "git_symlink")
    }

    // MARK: - Snapshot changes

    @Test("a size that no longer matches the listing is a reported change")
    func changedSize() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin", size: 1)

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.snapshotChanged)
        #expect(result.provenance(for: "snapshot")?.status == .changed)
        #expect(result.status == .changed)
    }

    @Test("a file that disappeared is a change, not a clean read")
    func missingEntry() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("blob.bin"))

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.facts.snapshotChanged)
        #expect(result.provenance(for: "snapshot")?.reason == "entry_missing")
    }

    @Test("a symlinked entry is not probed through its link")
    func symlinkedEntry() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let target = try fixture.write("payload", at: "target.bin")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("link.bin"),
                                                   withDestinationURL: target)
        let entry = try fixture.entry("target.bin").withPath("link.bin")

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false)).results.first)
        #expect(result.provenance(for: "snapshot")?.reason == "symlink")
        #expect(result.status == .failed)
    }

    // MARK: - Bounds, cancellation and provenance

    @Test("the entry bound is reported, never silently applied")
    func entryBound() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        var entries: [SourceEntry] = []
        for index in 0..<3 {
            try fixture.write("payload", at: "file\(index).bin")
            entries.append(try fixture.entry("file\(index).bin"))
        }

        let report = try fixture.probe(entries, request: .init(maxEntries: 2, includeGit: false))
        #expect(report.results.count == 2)
        #expect(report.skipped == 1)
        #expect(!report.cancelled)
        #expect(!report.timedOut)
    }

    @Test("an exhausted deadline stops the batch and says so")
    func deadline() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        var entries: [SourceEntry] = []
        for index in 0..<4 {
            try fixture.write("payload", at: "file\(index).bin")
            entries.append(try fixture.entry("file\(index).bin"))
        }

        let report = try fixture.probe(entries, request: .init(deadline: .zero, includeGit: false))
        #expect(report.timedOut)
        #expect(report.results.isEmpty)
    }

    @Test("cancellation stops the batch and is distinguishable from a deadline")
    func cancellation() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")
        let access = try SourceRootAccess(fixture.root)

        let report = EligibilityFactCollector.collect(access: access, entries: [entry],
                                                      request: .init(includeGit: false),
                                                      callerFacts: [:], isCancelled: { true })
        #expect(report.cancelled)
        #expect(!report.timedOut)
        #expect(report.results.isEmpty)
    }

    @Test("disabled probes report not-checked, never absent")
    func disabledProbes() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write(marker, at: "CACHEDIR.TAG")
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")

        let request = EligibilityProbeRequest(includeGit: false, includeNestedRepository: false,
                                              includeCacheMarker: false)
        let result = try #require(try fixture.probe([entry], request: request).results.first)

        #expect(result.facts.cacheMarker == .notChecked)
        #expect(result.facts.gitTracked == .unknown)
        #expect(result.facts.nestedRepository == .unknown)
        #expect(result.provenance(for: "cacheMarker")?.status == .notChecked)
        #expect(result.provenance(for: "cacheMarker")?.reason == "probe_disabled")
    }

    @Test("caller facts survive the probe untouched")
    func callerFactsArePreserved() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")
        let supplied = EligibilityFacts(entry: entry, businessEvidence: .confirmed,
                                       sourceCodeOrDeployment: .no, rebuildableArtifact: .yes)

        let result = try #require(try fixture.probe([entry], request: .init(includeGit: false),
                                                    caller: [entry.id: supplied]).results.first)
        #expect(result.facts.businessEvidence == .confirmed)
        #expect(result.facts.sourceCodeOrDeployment == .no)
        #expect(result.facts.rebuildableArtifact == .yes)
    }

    @Test("the scope identifier is stable and contains no path")
    func scopeIdentity() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")

        let first = try fixture.probe([entry], request: .init(includeGit: false))
        let second = try fixture.probe([entry], request: .init(includeGit: false))
        #expect(first.scopeID == second.scopeID)
        #expect(!first.scopeID.uuidString.lowercased().contains(fixture.root.lastPathComponent.lowercased()))
        #expect(first.factVersion == EligibilityFactCollector.factVersion)
    }

    // MARK: - Git

    @Test("a tracked file is established from the index of the scope root")
    func gitTrackedIndex() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try #require(GitTestSupport.git != nil, "git is not installed on this host")
        try fixture.write("tracked", at: "kept.txt")
        try fixture.write("untracked", at: "new.txt")
        try GitTestSupport.run(["-C", fixture.root.path, "init", "--quiet"])
        try GitTestSupport.run(["-C", fixture.root.path, "add", "kept.txt"])

        let kept = try fixture.entry("kept.txt")
        let added = try fixture.entry("new.txt")
        let report = try fixture.probe([kept, added],
                                       request: .init(includeNestedRepository: false, includeCacheMarker: false))
        let tracked = try #require(report.results.first { $0.sourceID == kept.id })
        let untracked = try #require(report.results.first { $0.sourceID == added.id })

        #expect(tracked.facts.gitTracked == .yes)
        #expect(untracked.facts.gitTracked == .no)
        #expect(tracked.provenance(for: "gitTracked")?.status == .confirmed)
    }

    @Test("a scope that is not a repository top-level is unknown, never untracked")
    func gitNotAtScopeRoot() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.write("payload", at: "blob.bin")
        let entry = try fixture.entry("blob.bin")

        // No repository here; with the ceiling at the scope root Git may not
        // ascend into a parent repository, so the fact stays unknown.
        let result = try #require(try fixture.probe([entry]).results.first)
        #expect(result.facts.gitTracked == .unknown)
        #expect(result.provenance(for: "gitTracked")?.status == .unavailable)
    }

    // MARK: - End to end with the classifier

    @Test("a verified cache exclusion needs known protecting facts")
    func cacheExclusionNeedsKnownFacts() throws {
        let verified = try Fixture(); defer { verified.cleanUp() }
        try verified.write(marker, at: "CACHEDIR.TAG")
        try verified.write("payload", at: "blob.bin")
        let entry = try verified.entry("blob.bin")
        let probed = try #require(try verified.probe([entry], request: .init(includeGit: false)).results.first)

        let policy = try EligibilityPolicy.shipped()
        // The probe confirmed the marker and the absence of a nested repository,
        // but Git tracking was not established: the exclusion cannot stand.
        let classification = EligibilityClassifier.classify(probed.facts, policy: policy)
        #expect(classification.decision == .review)
        #expect(classification.explanationCode == EligibilityClassifier.Reason.protectionFactUnknown)

        // With both facts established the same entry is excluded by the rule.
        let confirmed = EligibilityClassifier.classify(
            probed.facts.with(gitTracked: .no, nestedRepository: .no), policy: policy)
        #expect(confirmed.decision == .exclude)
        #expect(confirmed.decidedByRuleID == "verified-cache-directory")
    }

    @Test("the shipped policy carries a guard for every exclusion")
    func shippedPolicyGuards() throws {
        let policy = try EligibilityPolicy.shipped()
        for rule in policy.rules where rule.decision == .exclude {
            #expect(EligibilityFacts.knownFactNames.isSuperset(of: rule.protectionFacts))
            #expect(rule.ruleID != "verified-cache-directory" || rule.protectionFacts.contains("gitTracked"))
        }
        #expect(policy.policyVersion == EligibilityPolicy.currentVersion)
    }
}

// MARK: - Support

private extension SourceEntry {
    func withPath(_ path: String) -> SourceEntry {
        SourceEntry(id: id, rootID: rootID, relativePath: path, normalizedRelativePath: path.lowercased(),
                    state: state, hydrationPending: hydrationPending, sourceVersion: sourceVersion,
                    snapshotRevision: snapshotRevision, provider: provider,
                    snapshotFingerprint: snapshotFingerprint, sizeBytes: sizeBytes,
                    modificationTimeNanoseconds: modificationTimeNanoseconds, sha256: sha256)
    }
}

private extension EligibilityFacts {
    func with(gitTracked: EligibilityTriState, nestedRepository: EligibilityTriState) -> EligibilityFacts {
        EligibilityFacts(entry: entry, scanState: scanState, scanIssues: scanIssues,
                         gitTracked: gitTracked, cacheMarker: cacheMarker,
                         nestedRepository: nestedRepository, businessEvidence: businessEvidence,
                         sourceCodeOrDeployment: sourceCodeOrDeployment,
                         rebuildableArtifact: rebuildableArtifact, pathCollision: pathCollision,
                         snapshotChanged: snapshotChanged)
    }
}

private enum GitTestSupport {
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
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
