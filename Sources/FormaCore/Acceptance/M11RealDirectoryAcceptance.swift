import CryptoKit
import Foundation

/// Read-only acceptance over one explicitly authorized real directory.
///
/// This is the tool `MACOS-VALIDATION-BACKLOG` M11 level 4 needs: it scans a
/// directory the owner named, probes the read-only eligibility facts, classifies
/// every discovered record, and writes two artifacts with different audiences.
///
/// - The **private review sheet** stays on the machine that ran the scan. It
///   carries relative paths and fact provenance, because a human has to decide
///   what each `EXCLUDE` and `REVIEW` really is.
/// - The **sanitized summary** carries no path, no file name and no content. It
///   carries counts, coverage, review progress and the false-exclusion
///   arithmetic, because it may leave the machine.
///
/// What this deliberately does **not** do: it never writes to the source
/// directory, never writes DEVONthink, never calls a provider, never hydrates a
/// cloud placeholder and never enables the eligibility filter. The scan writes
/// only into the evidence directory it was given.
///
/// A completed run is not a passed acceptance. `coverage_state` says whether
/// the scan and the probe saw everything, `review_progress.state` says whether
/// a human has finished, and the false-exclusion rate is `N/A` until someone
/// has labelled the records.
public enum M11RealDirectoryAcceptance {

    // MARK: - Artifact names

    public enum Artifact {
        public static let privateReviewSheet = "private-review-sheet.json"
        public static let sanitizedSummary = "sanitized-summary.json"
        public static let scanCompleteness = "scan-completeness.json"
        public static let falseExclusion = "false-exclusion.json"
        public static let oneDriveCoverage = "onedrive-coverage.json"
        public static let humanLabels = "human-labels.json"
        public static let sha256Sums = "SHA256SUMS"
        public static let workspaceDatabase = "acceptance-workspace.sqlite"
    }

    // MARK: - Human labels

    /// What a reviewer concluded about one discovered record.
    ///
    /// `KEEP` is the only label that can turn into a false exclusion: it says
    /// the record is business material, so an `EXCLUDE` on it is a defect.
    /// `TECHNICAL_NOISE` and `UNCERTAIN` never enter the false-exclusion
    /// denominator.
    public enum HumanLabel: String, Codable, Sendable, CaseIterable {
        case keep = "KEEP"
        case technicalNoise = "TECHNICAL_NOISE"
        case uncertain = "UNCERTAIN"
    }

    /// One reviewer's verdict on one record.
    ///
    /// The optional snapshot fingerprint binds a verdict to the exact content
    /// the reviewer looked at. When it is present it must match the review
    /// sheet, so a verdict cannot be reused for different bytes.
    public struct Label: Codable, Sendable, Equatable {
        public let sourceID: UUID
        public let label: HumanLabel
        public let note: String?
        public let snapshotFingerprint: String?

        public init(sourceID: UUID, label: HumanLabel, note: String? = nil,
                    snapshotFingerprint: String? = nil) {
            self.sourceID = sourceID
            self.label = label
            self.note = note
            self.snapshotFingerprint = snapshotFingerprint
        }

        enum CodingKeys: String, CodingKey {
            case sourceID = "source_id", label, note
            case snapshotFingerprint = "snapshot_fingerprint"
        }
    }

    /// The file a reviewer fills in and the tool imports.
    public struct LabelFile: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let labels: [Label]

        public init(schemaVersion: String = "1.0", labels: [Label]) {
            self.schemaVersion = schemaVersion
            self.labels = labels
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", labels
        }
    }

    // MARK: - Private review sheet

    /// Why a fact is known, unknown or refused.
    public struct FactProvenanceRow: Codable, Sendable, Equatable {
        public let fact: String
        public let status: String
        public let reason: String?
        public let evidence: String?

        public init(fact: String, status: String, reason: String?, evidence: String?) {
            self.fact = fact
            self.status = status
            self.reason = reason
            self.evidence = evidence
        }

        enum CodingKeys: String, CodingKey {
            case fact, status, reason, evidence
        }
    }

    /// One discovered record with everything a reviewer needs.
    public struct ReviewRow: Codable, Sendable, Equatable {
        public let sourceID: UUID
        public let relativePath: String
        /// The fingerprint of the content this decision was made against.
        public let snapshotFingerprint: String
        public let decision: String
        public let ruleID: String?
        public let explanationCode: String
        public let followUp: String?
        public let overrideState: String
        public let hydrationPending: Bool
        public let facts: [FactProvenanceRow]
        public let humanLabel: HumanLabel?
        public let reviewerNote: String?

        enum CodingKeys: String, CodingKey {
            case sourceID = "source_id", relativePath = "relative_path"
            case snapshotFingerprint = "snapshot_fingerprint", decision
            case ruleID = "rule_id", explanationCode = "explanation_code", followUp = "follow_up"
            case overrideState = "override_state", hydrationPending = "hydration_pending"
            case facts, humanLabel = "human_label", reviewerNote = "reviewer_note"
        }
    }

    /// How much of the discovered set the probe actually reached.
    public struct ProbeCoverage: Codable, Sendable, Equatable {
        public let discovered: Int
        public let probed: Int
        public let skipped: Int
        public let timedOut: Bool
        public let cancelled: Bool

        public init(discovered: Int, probed: Int, skipped: Int, timedOut: Bool, cancelled: Bool) {
            self.discovered = discovered
            self.probed = probed
            self.skipped = skipped
            self.timedOut = timedOut
            self.cancelled = cancelled
        }

        enum CodingKeys: String, CodingKey {
            case discovered, probed, skipped, timedOut = "timed_out", cancelled
        }
    }

    /// The private artifact. It carries relative paths on purpose and must never
    /// leave the machine that ran the scan.
    public struct PrivateReviewSheet: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let policyID: String
        public let policyVersion: String
        public let policyDigest: String
        public let sourceScopeID: UUID
        public let sourceRootID: UUID
        /// The authorized root this sheet was made for. The sheet is private, so
        /// the absolute path may live here; the sanitized summary must not
        /// carry it.
        public let sourcePath: String
        public let scanState: String
        public let scanComplete: Bool
        public let scanIssueCount: Int
        public let probeCoverage: ProbeCoverage
        public let rows: [ReviewRow]
        /// Issues whose path never became a discovered record.
        public let unaccountedPaths: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", policyID = "policy_id"
            case policyVersion = "policy_version", policyDigest = "policy_digest"
            case sourceScopeID = "source_scope_id", sourceRootID = "source_root_id"
            case sourcePath = "source_path"
            case scanState = "scan_state", scanComplete = "scan_complete"
            case scanIssueCount = "scan_issue_count", probeCoverage = "probe_coverage"
            case rows, unaccountedPaths = "unaccounted_paths"
        }
    }

    // MARK: - Sanitized artifacts

    /// The false-exclusion arithmetic, with the state that says whether it
    /// means anything yet.
    public struct FalseExclusionMetric: Codable, Sendable, Equatable {
        /// `N/A` when no record was labelled `KEEP`, `MEASURED` otherwise.
        public let state: String
        public let numerator: Int?
        public let denominator: Int?
        public let rate: Double?
        public let unit: String
        public let population: String

        enum CodingKeys: String, CodingKey {
            case state, numerator, denominator, rate, unit, population
        }
    }

    /// How far the human review has got.
    public struct ReviewProgress: Codable, Sendable, Equatable {
        /// `not_required`, `unreviewed`, `in_progress` or `complete`.
        public let state: String
        /// Records that a reviewer must judge: every `EXCLUDE` and `REVIEW`.
        public let required: Int
        public let reviewed: Int
        public let unreviewed: Int
        public let keepSamples: Int
        public let technicalNoiseSamples: Int
        public let uncertainSamples: Int

        enum CodingKeys: String, CodingKey {
            case state, required, reviewed, unreviewed
            case keepSamples = "keep_samples"
            case technicalNoiseSamples = "technical_noise_samples"
            case uncertainSamples = "uncertain_samples"
        }
    }

    /// The artifact that may leave the machine. No path, no file name, no
    /// content.
    public struct SanitizedSummary: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let policyID: String
        public let policyVersion: String
        public let policyDigest: String
        /// `COMPLETE` only when the scan and the probe covered everything.
        public let coverageState: String
        public let discovered: Int
        public let include: Int
        public let exclude: Int
        public let review: Int
        public let deferred: Int
        public let unaccounted: Int
        public let scanIssueCount: Int
        public let scanState: String
        public let scanComplete: Bool
        public let probeCoverage: ProbeCoverage
        public let perRule: [String: Int]
        public let reviewProgress: ReviewProgress
        public let falseExclusion: FalseExclusionMetric
        /// SHA-256 of the private review sheet this summary was derived from.
        public let evidenceSHA256: String
        public let artifacts: [String: String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", policyID = "policy_id"
            case policyVersion = "policy_version", policyDigest = "policy_digest"
            case coverageState = "coverage_state"
            case discovered, include, exclude, review
            case deferred = "defer", unaccounted
            case scanIssueCount = "scan_issue_count", scanState = "scan_state"
            case scanComplete = "scan_complete", probeCoverage = "probe_coverage"
            case perRule = "per_rule", reviewProgress = "review_progress"
            case falseExclusion = "false_exclusion"
            case evidenceSHA256 = "evidence_sha256", artifacts
        }
    }

    /// Whether the scan saw everything it was supposed to see.
    public struct ScanCompletenessReport: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let coverageState: String
        public let scanState: String
        public let scanComplete: Bool
        public let discovered: Int
        public let scanIssueCount: Int
        public let unaccounted: Int
        public let probeCoverage: ProbeCoverage
        public let perDecision: [String: Int]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", coverageState = "coverage_state"
            case scanState = "scan_state", scanComplete = "scan_complete"
            case discovered, scanIssueCount = "scan_issue_count", unaccounted
            case probeCoverage = "probe_coverage", perDecision = "per_decision"
        }
    }

    /// The false-exclusion report, on its own, for a reviewer who only wants
    /// that number.
    public struct FalseExclusionReport: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let coverageState: String
        public let state: String
        public let numerator: Int?
        public let denominator: Int?
        public let rate: Double?
        public let unit: String
        public let population: String
        public let reviewProgress: ReviewProgress

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", coverageState = "coverage_state"
            case state, numerator, denominator, rate, unit, population
            case reviewProgress = "review_progress"
        }
    }

    /// What this run can say about OneDrive. It cannot say anything, and the
    /// report says so instead of staying silent.
    public struct OneDriveCoverageReport: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let state: String
        public let reason: String
        public let hydrationPendingRecords: Int
        public let notes: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", state, reason
            case hydrationPendingRecords = "hydration_pending_records", notes
        }
    }

    // MARK: - Request and outcome

    public struct Request: Sendable {
        /// The authorized directory. Must be absolute and must exist.
        public let source: URL
        /// Where the artifacts are written. Must be absolute and must not live
        /// inside the source.
        public let evidenceDirectory: URL
        /// Labels a reviewer already produced. Empty on the first scan.
        public let labels: [Label]
        /// `project-archive` or `vendor-library`.
        public let profileID: String
        /// Upper bound on probed records. Everything above it is reported as
        /// uncovered, never as verified.
        public let maxEntries: Int
        /// Wall-clock budget for the probe batch.
        public let deadlineSeconds: Int
        /// A dry run is the only mode. There is no import mode.
        public let dryRun: Bool

        public init(source: URL, evidenceDirectory: URL, labels: [Label] = [],
                    profileID: String = "project-archive", maxEntries: Int = 5_000,
                    deadlineSeconds: Int = 120, dryRun: Bool = true) {
            self.source = source
            self.evidenceDirectory = evidenceDirectory
            self.labels = labels
            self.profileID = profileID
            self.maxEntries = maxEntries
            self.deadlineSeconds = deadlineSeconds
            self.dryRun = dryRun
        }
    }

    /// What one run produced.
    public struct Outcome: Sendable {
        public let sheet: PrivateReviewSheet
        public let summary: SanitizedSummary
        public let completeness: ScanCompletenessReport
        public let falseExclusion: FalseExclusionReport
        public let oneDrive: OneDriveCoverageReport
        public let labels: [Label]
        /// File name to SHA-256, for every artifact except `SHA256SUMS` itself.
        public let artifactHashes: [String: String]
        public let files: [String: URL]
    }

    // MARK: - Errors

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case missingArgument(String)
        case unknownArgument(String)
        case relativeSourcePath
        case relativeEvidencePath
        case relativeLabelPath
        case missingSource
        case sourceNotDirectory
        case sourceIsEvidence
        case evidenceInsideSource
        case sourceInsideEvidence
        case dryRunRequired
        case invalidMaxEntries
        case invalidDeadline
        case unknownProfile
        case labelFileUnreadable
        case labelFileInvalid
        case sheetMissing
        case unknownLabelSourceID
        case duplicateLabelSourceID
        case sourceMismatch
        case evidenceDirectoryNotEmpty
        case unsafeEvidencePermissions
        case unsafeEvidenceSymlink(String)
        case policyChanged
        case labelSnapshotMismatch

        public var description: String {
            switch self {
            case .missingArgument(let name): return "missing required argument: \(name)"
            case .unknownArgument(let names): return "unknown argument(s): \(names)"
            case .relativeSourcePath: return "source path must be absolute"
            case .relativeEvidencePath: return "evidence directory must be absolute"
            case .relativeLabelPath: return "label file path must be absolute"
            case .missingSource: return "source directory does not exist"
            case .sourceNotDirectory: return "source path is not a directory"
            case .sourceIsEvidence: return "the evidence directory must not be the source directory"
            case .evidenceInsideSource: return "the evidence directory must not live inside the source directory"
            case .sourceInsideEvidence: return "the source directory must not live inside the evidence directory"
            case .dryRunRequired: return "--dry-run is required; this tool has no other mode"
            case .invalidMaxEntries: return "--max-entries must be a positive integer"
            case .invalidDeadline: return "--deadline-seconds must be a positive integer"
            case .unknownProfile: return "unknown mapping profile"
            case .labelFileUnreadable: return "the label file could not be read"
            case .labelFileInvalid: return "the label file is not a valid label document"
            case .sheetMissing: return "no private review sheet was found in the evidence directory"
            case .unknownLabelSourceID: return "a label refers to a source id that is not in the review sheet"
            case .duplicateLabelSourceID: return "two labels refer to the same source id"
            case .sourceMismatch: return "the source directory is not the one this review sheet was made for"
            case .evidenceDirectoryNotEmpty: return "the evidence directory already holds an evidence set; a new scan needs a new evidence run directory"
            case .unsafeEvidencePermissions: return "the evidence directory must be readable and writable by its owner only"
            case .unsafeEvidenceSymlink(let name): return "refusing to write through the symlink '\(name)'"
            case .policyChanged: return "the shipped policy changed since this review sheet was made; the old verdicts cannot be reused"
            case .labelSnapshotMismatch: return "a label refers to a snapshot that is not the one in the review sheet"
            }
        }
    }

    /// Which argument a path belongs to, so a refusal names the argument.
    public enum PathKind: String, Sendable {
        case source
        case evidenceDirectory
        case labels
    }

    /// Turns a user-supplied path into a URL, refusing a relative one.
    ///
    /// The check happens on the string, before `URL` can resolve it against the
    /// current directory: "the current directory" is not an authorization.
    public static func absoluteURL(from path: String, kind: PathKind) throws -> URL {
        guard path.hasPrefix("/") else {
            switch kind {
            case .source: throw Failure.relativeSourcePath
            case .evidenceDirectory: throw Failure.relativeEvidencePath
            case .labels: throw Failure.relativeLabelPath
            }
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Path validation

    /// The two directories the run is allowed to touch, after validation.
    public struct ResolvedPaths: Sendable, Equatable {
        public let source: URL
        public let evidenceDirectory: URL
    }

    /// Rejects every path shape this tool must not accept, before anything is
    /// read or written.
    ///
    /// - A relative path is refused: "the current directory" is not an
    ///   authorization.
    /// - The evidence directory may not be the source directory, inside it, or
    ///   contain it, so a report can never land inside the directory it
    ///   describes - not even through a symlink.
    public static func validate(source: URL, evidenceDirectory: URL, dryRun: Bool,
                                 requireExistingSource: Bool = true) throws -> ResolvedPaths {
        guard dryRun else { throw Failure.dryRunRequired }
        guard source.path.hasPrefix("/") else { throw Failure.relativeSourcePath }
        guard evidenceDirectory.path.hasPrefix("/") else { throw Failure.relativeEvidencePath }

        if requireExistingSource {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw Failure.missingSource
            }
            guard isDirectory.boolValue else { throw Failure.sourceNotDirectory }
        }

        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedEvidence = evidenceDirectory.resolvingSymlinksInPath().standardizedFileURL
        try checkSeparation(source: resolvedSource, evidence: resolvedEvidence)
        return ResolvedPaths(source: resolvedSource, evidenceDirectory: resolvedEvidence)
    }

    private static func checkSeparation(source: URL, evidence: URL) throws {
        if source.path == evidence.path { throw Failure.sourceIsEvidence }
        if contains(outer: source, inner: evidence) { throw Failure.evidenceInsideSource }
        if contains(outer: evidence, inner: source) { throw Failure.sourceInsideEvidence }
    }

    private static func contains(outer: URL, inner: URL) -> Bool {
        let prefix = outer.path.hasSuffix("/") ? outer.path : outer.path + "/"
        return inner.path.hasPrefix(prefix)
    }

    // MARK: - Scanning

    /// Scans the authorized directory, classifies every discovered record and
    /// writes the artifacts into the evidence directory.
    ///
    /// A scan always creates a **new** evidence run directory: an evidence
    /// directory that already holds something is refused, so a fresh scan can
    /// never overwrite an earlier review, its labels or its verdicts.
    public static func run(_ request: Request) async throws -> Outcome {
        let paths = try validate(source: request.source,
                                 evidenceDirectory: request.evidenceDirectory,
                                 dryRun: request.dryRun)
        guard request.maxEntries > 0 else { throw Failure.invalidMaxEntries }
        guard request.deadlineSeconds > 0 else { throw Failure.invalidDeadline }

        let evidence = try prepareEvidenceDirectory(paths.evidenceDirectory, source: paths.source)

        let profile = try mappingProfile(for: request.profileID)
        let policy = try EligibilityPolicy.shipped()

        let database = evidence.appendingPathComponent(Artifact.workspaceDatabase)
        try assertNotSymlink(database, name: Artifact.workspaceDatabase)
        let workspace = try SourceWorkspace(databaseURL: database)
        let scope = try await workspace.register(paths.source)
        let listing = try await workspace.scan(scope)
        let probe = try await workspace.probeEligibilityFacts(
            scope,
            request: EligibilityProbeRequest(maxEntries: request.maxEntries,
                                             deadline: .seconds(request.deadlineSeconds)))
        let keepIDs = Set(request.labels.filter { $0.label == .keep }.map(\.sourceID))
        let view = EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing, profile: profile, policy: policy, facts: probe.factsBySource,
            protectedSampleIDs: keepIDs, kind: .measured))
        let sheet = makeSheet(view: view, listing: listing, probe: probe, scope: scope,
                              sourcePath: paths.source.path,
                              policyID: view.policyID, policyVersion: view.policyVersion,
                              policyDigest: view.policyDigest, labels: request.labels)
        return try makeOutcome(sheet: sheet, labels: request.labels,
                               evidenceDirectory: evidence, source: paths.source)
    }

    /// Imports a reviewer's labels into an existing review sheet.
    ///
    /// Nothing is scanned and nothing in the source directory is read: the sheet
    /// already holds the decisions, and the labels only add a verdict per
    /// record. The metrics are recomputed from the sheet, so a reviewer can
    /// hand the labels back days later.
    ///
    /// The import is bound to the run that produced the sheet: the source path,
    /// the policy digest and the snapshot fingerprints all have to match, or the
    /// labels are refused instead of merged into a different run.
    public static func importLabels(source: URL, evidenceDirectory: URL,
                                     labels: [Label], dryRun: Bool) throws -> Outcome {
        let paths = try validate(source: source, evidenceDirectory: evidenceDirectory,
                                 dryRun: dryRun, requireExistingSource: false)
        let evidence = paths.evidenceDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: evidence.path) else {
            throw Failure.sheetMissing
        }
        try checkSeparation(source: paths.source, evidence: evidence)
        try assertOwnerOnly(evidence)
        let sheet = try loadSheet(from: evidence)
        guard sheet.sourcePath == paths.source.path else { throw Failure.sourceMismatch }
        let policy = try EligibilityPolicy.shipped()
        guard policy.digest == sheet.policyDigest else { throw Failure.policyChanged }
        let updated = try applyLabels(labels, to: sheet)
        return try makeOutcome(sheet: updated, labels: labels,
                               evidenceDirectory: evidence, source: paths.source)
    }

    // MARK: - Evidence directory safety

    /// Every file this tool writes, with the name it is refused under when it
    /// turns out to be a symlink.
    private static let fixedArtifactNames = [
        Artifact.privateReviewSheet, Artifact.sanitizedSummary, Artifact.scanCompleteness,
        Artifact.falseExclusion, Artifact.oneDriveCoverage, Artifact.humanLabels,
        Artifact.sha256Sums, Artifact.workspaceDatabase,
        Artifact.workspaceDatabase + "-wal", Artifact.workspaceDatabase + "-shm",
    ]

    /// Creates or checks the evidence run directory.
    ///
    /// The directory must be the owner's alone, must not be a symlink into the
    /// source, must not already hold an evidence set, and none of the fixed
    /// artifact names may be a symlink: writing through one would put the
    /// report outside the directory the reviewer was told about.
    private static func prepareEvidenceDirectory(_ evidence: URL, source: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: evidence.path) {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let settled = evidence.resolvingSymlinksInPath().standardizedFileURL
        try checkSeparation(source: source, evidence: settled)
        try assertOwnerOnly(settled)
        for name in fixedArtifactNames {
            try assertNotSymlink(settled.appendingPathComponent(name), name: name)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: settled.path)
        guard contents.isEmpty else { throw Failure.evidenceDirectoryNotEmpty }
        return settled
    }

    /// Refuses a path that is a symlink. A symlink at a fixed artifact name is
    /// the cheapest way to make a report land somewhere else.
    private static func assertNotSymlink(_ url: URL, name: String) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return
        }
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw Failure.unsafeEvidenceSymlink(name)
        }
    }

    /// Refuses an evidence directory that other users can reach.
    private static func assertOwnerOnly(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard permissions & 0o077 == 0 else { throw Failure.unsafeEvidencePermissions }
    }

    /// Restricts a private artifact to its owner, and refuses when that cannot
    /// be read back. Proving the write stayed private is part of the contract.
    private static func restrictToOwner(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0 else {
            throw Failure.unsafeEvidencePermissions
        }
    }

    /// Same, for files that may legitimately be absent (SQLite sidecars).
    private static func restrictToOwnerIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try restrictToOwner(url)
    }

    /// Locks down the workspace database and whichever sidecars SQLite created.
    private static func secureWorkspaceFiles(in evidence: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let name = Artifact.workspaceDatabase + suffix
            let url = evidence.appendingPathComponent(name)
            try assertNotSymlink(url, name: name)
            try restrictToOwnerIfExists(url)
        }
    }

    // MARK: - Label import

    /// Reads the private review sheet an earlier run wrote.
    public static func loadSheet(from evidenceDirectory: URL) throws -> PrivateReviewSheet {
        let url = evidenceDirectory.appendingPathComponent(Artifact.privateReviewSheet)
        try assertNotSymlink(url, name: Artifact.privateReviewSheet)
        guard let data = try? Data(contentsOf: url) else { throw Failure.sheetMissing }
        guard let sheet = try? FormaJSON.decode(PrivateReviewSheet.self, from: data) else {
            throw Failure.sheetMissing
        }
        return sheet
    }

    /// Reads a label document.
    public static func loadLabels(from url: URL) throws -> [Label] {
        guard let data = try? Data(contentsOf: url) else { throw Failure.labelFileUnreadable }
        guard let file = try? FormaJSON.decode(LabelFile.self, from: data) else {
            throw Failure.labelFileInvalid
        }
        return file.labels
    }

    /// Merges a reviewer's labels into the sheet.
    ///
    /// The merge never rescans: a reviewer can fill the sheet in over hours and
    /// hand the labels back without touching the source directory again.
    public static func applyLabels(_ labels: [Label], to sheet: PrivateReviewSheet) throws -> PrivateReviewSheet {
        var bySource: [UUID: Label] = [:]
        for label in labels {
            if bySource[label.sourceID] != nil { throw Failure.duplicateLabelSourceID }
            bySource[label.sourceID] = label
        }
        let known = Set(sheet.rows.map(\.sourceID))
        for id in bySource.keys where !known.contains(id) { throw Failure.unknownLabelSourceID }

        // A verdict that names a snapshot must name this one. Checked before any
        // merge, so a refused import never leaves a half-updated sheet.
        for row in sheet.rows {
            guard let label = bySource[row.sourceID] else { continue }
            if let fingerprint = label.snapshotFingerprint,
               fingerprint != row.snapshotFingerprint {
                throw Failure.labelSnapshotMismatch
            }
        }

        let rows = sheet.rows.map { row -> ReviewRow in
            guard let label = bySource[row.sourceID] else { return row }
            return ReviewRow(sourceID: row.sourceID, relativePath: row.relativePath,
                             snapshotFingerprint: row.snapshotFingerprint,
                             decision: row.decision, ruleID: row.ruleID,
                             explanationCode: row.explanationCode, followUp: row.followUp,
                             overrideState: row.overrideState,
                             hydrationPending: row.hydrationPending, facts: row.facts,
                             humanLabel: label.label, reviewerNote: label.note)
        }
        return PrivateReviewSheet(schemaVersion: sheet.schemaVersion, policyID: sheet.policyID,
                                  policyVersion: sheet.policyVersion, policyDigest: sheet.policyDigest,
                                  sourceScopeID: sheet.sourceScopeID, sourceRootID: sheet.sourceRootID,
                                  sourcePath: sheet.sourcePath,
                                  scanState: sheet.scanState, scanComplete: sheet.scanComplete,
                                  scanIssueCount: sheet.scanIssueCount,
                                  probeCoverage: sheet.probeCoverage, rows: rows,
                                  unaccountedPaths: sheet.unaccountedPaths)
    }

    // MARK: - Sheet construction

    private static func makeSheet(view: EligibilityView, listing: SourceListing,
                                  probe: EligibilityProbeReport, scope: SourceScope,
                                  sourcePath: String,
                                  policyID: String, policyVersion: String, policyDigest: String,
                                  labels: [Label]) -> PrivateReviewSheet {
        var bySource: [UUID: Label] = [:]
        for label in labels { bySource[label.sourceID] = label }
        let provenance = Dictionary(probe.results.map { ($0.sourceID, $0.provenance) },
                                    uniquingKeysWith: { first, _ in first })
        let rows = view.entries.map { item -> ReviewRow in
            let label = bySource[item.sourceID]
            return ReviewRow(sourceID: item.sourceID, relativePath: item.entry.relativePath,
                             snapshotFingerprint: item.entry.snapshotFingerprint,
                             decision: item.decision.rawValue, ruleID: item.decidedByRuleID,
                             explanationCode: item.explanationCode,
                             followUp: item.followUp?.rawValue,
                             overrideState: item.overrideState.rawValue,
                             hydrationPending: item.entry.hydrationPending,
                             facts: (provenance[item.sourceID] ?? []).map {
                                 FactProvenanceRow(fact: $0.fact, status: $0.status.rawValue,
                                                   reason: $0.reason, evidence: $0.evidence)
                             },
                             humanLabel: label?.label, reviewerNote: label?.note)
        }
        let discoveredPaths = Set(listing.entries.map(\.normalizedRelativePath))
        let unaccounted = listing.issues
            .filter { !discoveredPaths.contains($0.relativePath) }
            .map(\.relativePath)
            .sorted()
        return PrivateReviewSheet(schemaVersion: "1.0", policyID: policyID,
                                  policyVersion: policyVersion, policyDigest: policyDigest,
                                  sourceScopeID: scope.id, sourceRootID: scope.rootID,
                                  sourcePath: sourcePath,
                                  scanState: listing.state.rawValue, scanComplete: listing.isComplete,
                                  scanIssueCount: listing.issues.count,
                                  probeCoverage: ProbeCoverage(discovered: listing.entries.count,
                                                               probed: probe.results.count,
                                                               skipped: probe.skipped,
                                                               timedOut: probe.timedOut,
                                                               cancelled: probe.cancelled),
                                  rows: rows, unaccountedPaths: unaccounted)
    }

    // MARK: - Reports and artifacts

    private static func makeOutcome(sheet: PrivateReviewSheet, labels: [Label],
                                    evidenceDirectory: URL, source: URL) throws -> Outcome {
        // The directory may have been swapped between the scan and the write.
        // Re-check before anything is written, and fail closed if it moved.
        let settled = evidenceDirectory.resolvingSymlinksInPath().standardizedFileURL
        try checkSeparation(source: source, evidence: settled)
        try assertOwnerOnly(settled)
        for name in fixedArtifactNames {
            try assertNotSymlink(settled.appendingPathComponent(name), name: name)
        }
        // The workspace database and its sidecars hold relative paths, so they
        // are private evidence too and get the same owner-only mode.
        try secureWorkspaceFiles(in: settled)

        let sheetData = try FormaJSON.encode(sheet, pretty: true)
        let sheetHash = sha256Hex(sheetData)
        let summary = summarize(sheet: sheet, evidenceHash: sheetHash)
        let completeness = completenessReport(sheet: sheet)
        let falseExclusion = falseExclusionReport(sheet: sheet)
        let oneDrive = oneDriveReport(sheet: sheet)

        var hashes: [String: String] = [Artifact.privateReviewSheet: sheetHash]
        var files: [String: URL] = [:]
        try write(sheetData, to: settled, name: Artifact.privateReviewSheet, files: &files)

        let summaryData = try FormaJSON.encode(summary, pretty: true)
        hashes[Artifact.sanitizedSummary] = sha256Hex(summaryData)
        try write(summaryData, to: settled, name: Artifact.sanitizedSummary, files: &files)

        let completenessData = try FormaJSON.encode(completeness, pretty: true)
        hashes[Artifact.scanCompleteness] = sha256Hex(completenessData)
        try write(completenessData, to: settled, name: Artifact.scanCompleteness, files: &files)

        let falseExclusionData = try FormaJSON.encode(falseExclusion, pretty: true)
        hashes[Artifact.falseExclusion] = sha256Hex(falseExclusionData)
        try write(falseExclusionData, to: settled, name: Artifact.falseExclusion, files: &files)

        let oneDriveData = try FormaJSON.encode(oneDrive, pretty: true)
        hashes[Artifact.oneDriveCoverage] = sha256Hex(oneDriveData)
        try write(oneDriveData, to: settled, name: Artifact.oneDriveCoverage, files: &files)

        if !labels.isEmpty {
            let labelFile = LabelFile(labels: labels.sorted { $0.sourceID.uuidString < $1.sourceID.uuidString })
            let labelData = try FormaJSON.encode(labelFile, pretty: true)
            hashes[Artifact.humanLabels] = sha256Hex(labelData)
            try write(labelData, to: settled, name: Artifact.humanLabels, files: &files)
        }

        let sums = hashes.keys.sorted().compactMap { key in
            hashes[key].map { "\($0)  \(key)" }
        }.joined(separator: "\n") + "\n"
        try write(Data(sums.utf8), to: settled, name: Artifact.sha256Sums, files: &files)

        return Outcome(sheet: sheet, summary: summary, completeness: completeness,
                       falseExclusion: falseExclusion, oneDrive: oneDrive, labels: labels,
                       artifactHashes: hashes, files: files)
    }

    /// Writes one artifact: never through a symlink, never readable by anyone
    /// but its owner.
    private static func write(_ data: Data, to directory: URL, name: String,
                              files: inout [String: URL]) throws {
        let url = directory.appendingPathComponent(name)
        try assertNotSymlink(url, name: name)
        try data.write(to: url, options: .atomic)
        try restrictToOwner(url)
        files[name] = url
    }

    private static func summarize(sheet: PrivateReviewSheet, evidenceHash: String) -> SanitizedSummary {
        var include = 0, exclude = 0, review = 0, deferred = 0
        var perRule: [String: Int] = [:]
        for row in sheet.rows {
            switch row.decision {
            case EligibilityDecision.include.rawValue: include += 1
            case EligibilityDecision.exclude.rawValue: exclude += 1
            case EligibilityDecision.review.rawValue: review += 1
            default: deferred += 1
            }
            if let rule = row.ruleID { perRule[rule, default: 0] += 1 }
        }
        let coverage = coverageState(sheet: sheet)
        let progress = reviewProgress(sheet: sheet)
        let falseExclusion = falseExclusionMetric(sheet: sheet)
        return SanitizedSummary(
            schemaVersion: "1.0", policyID: sheet.policyID, policyVersion: sheet.policyVersion,
            policyDigest: sheet.policyDigest, coverageState: coverage,
            discovered: sheet.rows.count, include: include, exclude: exclude, review: review,
            deferred: deferred, unaccounted: sheet.unaccountedPaths.count,
            scanIssueCount: sheet.scanIssueCount, scanState: sheet.scanState,
            scanComplete: sheet.scanComplete, probeCoverage: sheet.probeCoverage,
            perRule: perRule, reviewProgress: progress, falseExclusion: falseExclusion,
            evidenceSHA256: evidenceHash,
            artifacts: [Artifact.privateReviewSheet: evidenceHash])
    }

    private static func coverageState(sheet: PrivateReviewSheet) -> String {
        let coverage = sheet.probeCoverage
        let complete = sheet.scanComplete && coverage.skipped == 0 && !coverage.timedOut
            && !coverage.cancelled
        return complete ? "COMPLETE" : "PARTIAL"
    }

    private static func reviewProgress(sheet: PrivateReviewSheet) -> ReviewProgress {
        let required = sheet.rows.filter {
            $0.decision == EligibilityDecision.exclude.rawValue
                || $0.decision == EligibilityDecision.review.rawValue
        }
        let reviewed = required.filter { $0.humanLabel != nil }.count
        let keep = sheet.rows.filter { $0.humanLabel == .keep }.count
        let noise = sheet.rows.filter { $0.humanLabel == .technicalNoise }.count
        let uncertain = sheet.rows.filter { $0.humanLabel == .uncertain }.count
        let state: String
        if required.isEmpty { state = "not_required" }
        else if reviewed == 0 { state = "unreviewed" }
        else if reviewed < required.count { state = "in_progress" }
        else { state = "complete" }
        return ReviewProgress(state: state, required: required.count, reviewed: reviewed,
                              unreviewed: required.count - reviewed, keepSamples: keep,
                              technicalNoiseSamples: noise, uncertainSamples: uncertain)
    }

    private static func falseExclusionMetric(sheet: PrivateReviewSheet) -> FalseExclusionMetric {
        let keep = sheet.rows.filter { $0.humanLabel == .keep }
        let excluded = keep.filter { $0.decision == EligibilityDecision.exclude.rawValue }.count
        let population = "human-labelled KEEP records"
        guard !keep.isEmpty else {
            return FalseExclusionMetric(state: "N/A", numerator: nil, denominator: nil, rate: nil,
                                        unit: "records", population: population)
        }
        return FalseExclusionMetric(state: "MEASURED", numerator: excluded, denominator: keep.count,
                                    rate: Double(excluded) / Double(keep.count), unit: "records",
                                    population: population)
    }

    private static func completenessReport(sheet: PrivateReviewSheet) -> ScanCompletenessReport {
        var perDecision: [String: Int] = [:]
        for row in sheet.rows { perDecision[row.decision, default: 0] += 1 }
        return ScanCompletenessReport(schemaVersion: "1.0", coverageState: coverageState(sheet: sheet),
                                      scanState: sheet.scanState, scanComplete: sheet.scanComplete,
                                      discovered: sheet.rows.count, scanIssueCount: sheet.scanIssueCount,
                                      unaccounted: sheet.unaccountedPaths.count,
                                      probeCoverage: sheet.probeCoverage, perDecision: perDecision)
    }

    private static func falseExclusionReport(sheet: PrivateReviewSheet) -> FalseExclusionReport {
        let metric = falseExclusionMetric(sheet: sheet)
        return FalseExclusionReport(schemaVersion: "1.0", coverageState: coverageState(sheet: sheet),
                                    state: metric.state, numerator: metric.numerator,
                                    denominator: metric.denominator, rate: metric.rate,
                                    unit: metric.unit, population: metric.population,
                                    reviewProgress: reviewProgress(sheet: sheet))
    }

    private static func oneDriveReport(sheet: PrivateReviewSheet) -> OneDriveCoverageReport {
        let pending = sheet.rows.filter(\.hydrationPending).count
        return OneDriveCoverageReport(
            schemaVersion: "1.0", state: "NOT_VERIFIED",
            reason: "this run scanned a local directory and never opened a OneDrive scope, "
                + "so no dataless, hydration or permission-failure behaviour was observed",
            hydrationPendingRecords: pending,
            notes: "OneDrive coverage needs its own authorized scope and a separate run")
    }

    // MARK: - Helpers

    private static func mappingProfile(for identifier: String) throws -> MappingProfile {
        switch identifier {
        case "project-archive": return try MappingProfile.projectArchive()
        case "vendor-library": return try MappingProfile.vendorLibrary()
        default: throw Failure.unknownProfile
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
