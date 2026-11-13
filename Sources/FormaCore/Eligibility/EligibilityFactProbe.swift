import CryptoKit
import Darwin
import Foundation

// Read-only eligibility fact probes.
//
// Every observation here is a *read*: open, fstat, read, and (for Git) a
// sandboxed `git ls-files` that cannot write. Nothing creates, deletes, moves or
// rewrites anything, and every path is opened relative to a descriptor obtained
// from `SourceRootAccess`, which refuses `O_NOFOLLOW` traversal, verifies the
// root identity and refuses a device change mid-walk.
//
// The probe answers three facts and leaves the rest to the caller:
//
//   gitTracked        - is this path in the index of the repository whose
//                       top-level *is* the authorized scope?
//   nestedRepository  - does any directory between the scope root and the file
//                       contain a `.git` directory or file?
//   cacheMarker       - does an ancestor contain a CACHEDIR.TAG with the
//                       standard signature?
//
// `businessEvidence`, `sourceCodeOrDeployment` and `rebuildableArtifact` are
// never inferred here: they are decisions a person or a future authorized probe
// makes, and the collector never overwrites a caller-supplied value.
//
// Every fact is fail-safe. A probe that did not run, could not run, or could not
// finish yields `unknown`, and the classifier turns an unknown protecting fact
// into REVIEW rather than EXCLUDE.

public enum EligibilityProbeStatus: String, Codable, Sendable, CaseIterable {
    /// Established and usable.
    case confirmed
    /// The probe did not run for this fact.
    case notChecked = "not_checked"
    /// The fact cannot be established on this host or for this source (Git is
    /// absent, or the scope root is not a repository top-level).
    case unavailable
    /// The probe ran and failed, or the metadata could not be read reliably.
    case failed
    /// The source or its metadata changed while the probe was running.
    case changed
    /// Establishing the fact would require reading outside the authorized root.
    case outsideAuthorization = "outside_authorization"
}

public struct EligibilityFactProvenance: Codable, Sendable, Equatable {
    public let fact: String
    public let status: EligibilityProbeStatus
    /// Stable code, never a path: e.g. `git_not_installed`, `marker_signature`.
    public let reason: String?
    /// A short digest or count that lets a reviewer re-check the observation
    /// without seeing a path or a name.
    public let evidence: String?

    public init(fact: String, status: EligibilityProbeStatus, reason: String? = nil,
                evidence: String? = nil) {
        self.fact = fact
        self.status = status
        self.reason = reason
        self.evidence = evidence
    }
}

public struct EligibilityProbeRequest: Sendable, Equatable {
    /// Upper bound on entries probed in one call. The rest are reported as
    /// `skipped`, never silently dropped.
    public let maxEntries: Int
    /// Wall-clock budget for the whole batch.
    public let deadline: Duration
    /// Wall-clock budget for one Git invocation.
    public let gitTimeout: Duration
    public let gitOutputLimitBytes: Int
    public let includeGit: Bool
    public let includeNestedRepository: Bool
    public let includeCacheMarker: Bool

    public init(maxEntries: Int = 5_000, deadline: Duration = .seconds(10),
                gitTimeout: Duration = .seconds(5), gitOutputLimitBytes: Int = 32 * 1_024 * 1_024,
                includeGit: Bool = true, includeNestedRepository: Bool = true,
                includeCacheMarker: Bool = true) {
        self.maxEntries = max(0, maxEntries)
        self.deadline = max(.zero, deadline)
        self.gitTimeout = max(.milliseconds(100), gitTimeout)
        self.gitOutputLimitBytes = max(1_024, gitOutputLimitBytes)
        self.includeGit = includeGit
        self.includeNestedRepository = includeNestedRepository
        self.includeCacheMarker = includeCacheMarker
    }
}

public struct EligibilityProbeResult: Sendable, Equatable {
    public let sourceID: UUID
    public let snapshotFingerprint: String
    public let facts: EligibilityFacts
    public let provenance: [EligibilityFactProvenance]
    public let status: EligibilityProbeStatus

    public func provenance(for fact: String) -> EligibilityFactProvenance? {
        provenance.first { $0.fact == fact }
    }
}

public struct EligibilityProbeReport: Sendable, Equatable {
    /// Stable identity of the authorized root, derived from its file identity and
    /// never from its path.
    public let scopeID: UUID
    /// Version of the fact contract. A consumer can refuse facts produced by a
    /// version it does not understand.
    public let factVersion: String
    public let results: [EligibilityProbeResult]
    /// Entries beyond `maxEntries`, which were not probed at all.
    public let skipped: Int
    public let cancelled: Bool
    public let timedOut: Bool
    /// `SourceRootAccess.openDirectory` calls made while probing, including the
    /// ones that failed. Each call resolves a whole relative path, so this is a
    /// lower bound on descriptors opened. Every entry makes one call for its own
    /// stat, and each directory whose metadata is read is called once per batch;
    /// publishing the number keeps the cost visible instead of implied.
    public let descriptorOpens: Int
    /// Git processes started. Zero when the probe was disabled, one for a scope
    /// that is not a repository top-level, two for one that is.
    public let gitInvocations: Int

    public var factsBySource: [UUID: EligibilityFacts] {
        Dictionary(results.map { ($0.sourceID, $0.facts) }, uniquingKeysWith: { _, last in last })
    }
}

enum EligibilityFactCollector {
    static let factVersion = "eligibility-facts.v1"

    /// Probes `entries` inside the authorized `access`.
    ///
    /// `callerFacts` carries facts the caller already established (a confirmed
    /// business decision, a manual classification). The collector copies those
    /// fields verbatim and only fills the facts it actually observed, so a probe
    /// can never overwrite a person's confirmation.
    static func collect(access: SourceRootAccess, entries: [SourceEntry],
                        request: EligibilityProbeRequest = .init(),
                        callerFacts: [UUID: EligibilityFacts] = [:],
                        isCancelled: () -> Bool = { Task.isCancelled }) -> EligibilityProbeReport {
        let start = ContinuousClock.now
        let slice = Array(entries.prefix(request.maxEntries))
        var gitInvocations = 0
        let git = request.includeGit
            ? GitSnapshot.load(access: access, request: request, invocations: &gitInvocations)
            : .disabled
        let probes = DirectoryProbes(access: access, request: request)

        var results: [EligibilityProbeResult] = []
        results.reserveCapacity(slice.count)
        var cancelled = false
        var timedOut = false

        for entry in slice {
            if isCancelled() { cancelled = true; break }
            if start.duration(to: .now) > request.deadline { timedOut = true; break }

            let caller = callerFacts[entry.id]
            let parent = Self.parentDirectory(of: entry.relativePath)
            var provenance: [EligibilityFactProvenance] = []
            var gitTracked: EligibilityTriState = .unknown
            var nested: EligibilityTriState = .unknown
            var cacheMarker: EligibilityCacheMarker = .notChecked
            var snapshotChanged = false

            switch probes.statFile(parent: parent, name: Self.basename(of: entry.relativePath)) {
            case .present(let metadata):
                let sizeMatches = entry.sizeBytes == nil || entry.sizeBytes == metadata.sizeBytes
                let mtimeMatches = entry.modificationTimeNanoseconds == nil
                    || entry.modificationTimeNanoseconds == metadata.modifiedNanoseconds
                if !sizeMatches || !mtimeMatches || metadata.device != access.metadata.device {
                    snapshotChanged = true
                    provenance.append(.init(fact: "snapshot", status: .changed,
                                            reason: sizeMatches && mtimeMatches ? "device_changed"
                                                : "metadata_mismatch"))
                }
            case .missing:
                snapshotChanged = true
                provenance.append(.init(fact: "snapshot", status: .changed, reason: "entry_missing"))
            case .unreadable(let reason):
                provenance.append(.init(fact: "snapshot", status: .failed, reason: reason))
            case .traversalRefused:
                provenance.append(.init(fact: "snapshot", status: .outsideAuthorization,
                                        reason: "path_traversal"))
            }

            if request.includeGit {
                let observation = git.observation(for: entry.relativePath)
                gitTracked = observation.tracked
                provenance.append(.init(fact: "gitTracked", status: observation.status,
                                        reason: observation.reason, evidence: observation.evidence))
            } else {
                provenance.append(.init(fact: "gitTracked", status: .notChecked, reason: "probe_disabled"))
            }

            if request.includeNestedRepository {
                let observation = probes.nestedRepository(parent: parent)
                nested = observation.isNested
                provenance.append(.init(fact: "nestedRepository", status: observation.status,
                                        reason: observation.reason, evidence: observation.evidence))
            } else {
                provenance.append(.init(fact: "nestedRepository", status: .notChecked, reason: "probe_disabled"))
            }

            if request.includeCacheMarker {
                let observation = probes.cacheMarker(parent: parent)
                cacheMarker = observation.marker
                provenance.append(.init(fact: "cacheMarker", status: observation.status,
                                        reason: observation.reason, evidence: observation.evidence))
            } else {
                provenance.append(.init(fact: "cacheMarker", status: .notChecked, reason: "probe_disabled"))
            }

            let facts = EligibilityFacts(
                entry: entry, scanState: caller?.scanState ?? .complete,
                scanIssues: caller?.scanIssues ?? [],
                gitTracked: gitTracked,
                cacheMarker: cacheMarker,
                nestedRepository: nested,
                businessEvidence: caller?.businessEvidence ?? .unknown,
                sourceCodeOrDeployment: caller?.sourceCodeOrDeployment ?? .unknown,
                rebuildableArtifact: caller?.rebuildableArtifact ?? .unknown,
                pathCollision: caller?.pathCollision ?? false,
                snapshotChanged: snapshotChanged || (caller?.snapshotChanged ?? false))

            results.append(EligibilityProbeResult(
                sourceID: entry.id, snapshotFingerprint: entry.snapshotFingerprint,
                facts: facts, provenance: provenance, status: Self.aggregate(provenance)))
        }

        return EligibilityProbeReport(scopeID: Self.scopeIdentifier(access), factVersion: factVersion,
                                      results: results, skipped: max(0, entries.count - slice.count),
                                      cancelled: cancelled, timedOut: timedOut,
                                      descriptorOpens: probes.descriptorOpens,
                                      gitInvocations: gitInvocations)
    }

    /// The weakest status across the facts this entry needed.
    static func aggregate(_ provenance: [EligibilityFactProvenance]) -> EligibilityProbeStatus {
        let rank: [EligibilityProbeStatus] = [.confirmed, .notChecked, .unavailable, .failed,
                                             .outsideAuthorization, .changed]
        var worst = 0
        for item in provenance {
            if let position = rank.firstIndex(of: item.status) { worst = max(worst, position) }
        }
        return rank[worst]
    }

    /// Derived from the root's file identity, so the same scope has the same
    /// identifier across runs and different scopes do not collide.
    static func scopeIdentifier(_ access: SourceRootAccess) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("eligibility.scope.v1|\(access.rootIdentity)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func parentDirectory(of relativePath: String) -> String {
        guard let index = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[relativePath.startIndex..<index])
    }

    static func basename(of relativePath: String) -> String {
        guard let index = relativePath.lastIndex(of: "/") else { return relativePath }
        return String(relativePath[relativePath.index(after: index)...])
    }
}

// MARK: - Path-confined directory probing

/// Per-batch memo of directory observations.
///
/// A 10k-entry listing shares a handful of directories, so each directory's
/// `.git` and `CACHEDIR.TAG` are read once and the answer reused. Nothing is
/// cached across batches: a later call re-observes.
final class DirectoryProbes {
    struct GitObservation {
        var isNested: EligibilityTriState
        var status: EligibilityProbeStatus
        var reason: String?
        var evidence: String?
    }

    struct MarkerObservation {
        var marker: EligibilityCacheMarker
        var status: EligibilityProbeStatus
        var reason: String?
        var evidence: String?
    }

    enum FileState {
        case present(SourceFileMetadata)
        case missing
        case unreadable(String)
        case traversalRefused
    }

    enum MarkerState {
        case verified(String)
        case presentUnverified(String)
        case unreadable(String)
        case absent
    }

    enum GitMarkerState {
        case repository(String)
        case outsideAuthorization(String)
        case unreadable(String)
        case absent
    }

    private let access: SourceRootAccess
    private let request: EligibilityProbeRequest
    private var gitByDirectory: [String: GitMarkerState] = [:]
    private var markerByDirectory: [String: MarkerState] = [:]
    /// Descriptor opens actually attempted, including the ones that failed.
    private(set) var descriptorOpens = 0

    init(access: SourceRootAccess, request: EligibilityProbeRequest) {
        self.access = access
        self.request = request
    }

    func statFile(parent: String, name: String) -> FileState {
        guard Self.isSafeComponent(name) else { return .traversalRefused }
        descriptorOpens += 1
        guard let descriptor = try? access.openDirectory(parent) else { return .unreadable("open_failed") }
        defer { close(descriptor) }
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .unreadable("stat_failed")
        }
        let metadata = SourceFileMetadata(value)
        guard !metadata.isSymlink else { return .unreadable("symlink") }
        return .present(metadata)
    }

    /// Whether any directory strictly below the scope root and at or above the
    /// entry's parent contains a `.git` directory or file.
    func nestedRepository(parent: String) -> GitObservation {
        var unknownReason: String?
        var unknownDirectory = ""
        var visited = ""
        for component in parent.split(separator: "/").map(String.init) {
            guard Self.isSafeComponent(component) else {
                return GitObservation(isNested: .unknown, status: .outsideAuthorization,
                                      reason: "path_traversal", evidence: nil)
            }
            visited = visited.isEmpty ? component : "\(visited)/\(component)"
            switch gitMarker(directory: visited) {
            case .repository(let evidence):
                return GitObservation(isNested: .yes, status: .confirmed,
                                      reason: "nested_repository", evidence: evidence)
            case .outsideAuthorization(let reason):
                return GitObservation(isNested: .unknown, status: .outsideAuthorization,
                                      reason: reason, evidence: nil)
            case .unreadable(let reason):
                if unknownReason == nil { unknownReason = reason; unknownDirectory = visited }
            case .absent:
                continue
            }
        }
        if let reason = unknownReason {
            return GitObservation(isNested: .unknown, status: .failed, reason: reason,
                                  evidence: Self.shortDigest(unknownDirectory))
        }
        return GitObservation(isNested: .no, status: .confirmed, reason: "no_nested_repository",
                              evidence: "depth=\(parent.split(separator: "/").count)")
    }

    /// The nearest ancestor marker, nearest first. A valid marker wins; an
    /// invalid or unreadable one is reported rather than treated as absent.
    func cacheMarker(parent: String) -> MarkerObservation {
        var directories: [String] = []
        var current = parent
        while true {
            directories.append(current)
            if current.isEmpty { break }
            current = EligibilityFactCollector.parentDirectory(of: current)
        }
        var invalid: (EligibilityCacheMarker, String, String)?
        for directory in directories {
            switch marker(directory: directory) {
            case .verified(let evidence):
                return MarkerObservation(marker: .verifiedSignature, status: .confirmed,
                                         reason: "marker_signature", evidence: evidence)
            case .presentUnverified(let evidence):
                if invalid == nil { invalid = (.presentUnverified, "marker_signature_invalid", evidence) }
            case .unreadable(let reason):
                if invalid == nil { invalid = (.unreadable, reason, "marker_unreadable") }
            case .absent:
                continue
            }
        }
        if let (marker, reason, evidence) = invalid {
            return MarkerObservation(marker: marker, status: .failed, reason: reason, evidence: evidence)
        }
        return MarkerObservation(marker: .absent, status: .confirmed, reason: "no_marker",
                                 evidence: "ancestors=\(directories.count)")
    }

    // MARK: - Directory observations (memoized)

    private func marker(directory: String) -> MarkerState {
        if let cached = markerByDirectory[directory] { return cached }
        descriptorOpens += 1
        guard let descriptor = try? access.openDirectory(directory) else {
            let state = MarkerState.unreadable("open_failed")
            markerByDirectory[directory] = state
            return state
        }
        defer { close(descriptor) }
        let state = Self.readMarker(directory: descriptor, limit: 1_024)
        markerByDirectory[directory] = state
        return state
    }

    private func gitMarker(directory: String) -> GitMarkerState {
        if let cached = gitByDirectory[directory] { return cached }
        descriptorOpens += 1
        guard let descriptor = try? access.openDirectory(directory) else {
            let state = GitMarkerState.unreadable("open_failed")
            gitByDirectory[directory] = state
            return state
        }
        defer { close(descriptor) }
        let state = Self.readGitMarker(directory: descriptor, directoryRelative: directory, access: access)
        gitByDirectory[directory] = state
        return state
    }

    // MARK: - Raw reads (no symlink following, bounded)

    static func readMarker(directory: Int32, limit: Int) -> MarkerState {
        let outcome = readFile(directory: directory, name: "CACHEDIR.TAG", limit: limit)
        switch outcome {
        case .absent:
            return .absent
        case .unreadable(let reason):
            return .unreadable(reason)
        case .data(let data):
            let digest = shortDigest(data)
            let signature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
            return data.starts(with: signature) ? .verified(digest) : .presentUnverified(digest)
        }
    }

    /// A `.git` file points at a gitdir that may live elsewhere. When it resolves
    /// outside the authorized root the observation stops here: following it would
    /// mean reading a directory the scope does not authorize.
    static func readGitMarker(directory: Int32, directoryRelative: String,
                              access: SourceRootAccess) -> GitMarkerState {
        var value = stat()
        guard fstatat(directory, ".git", &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .absent : .unreadable("git_metadata_unreadable")
        }
        let metadata = SourceFileMetadata(value)
        if metadata.isSymlink { return .unreadable("git_symlink") }
        if metadata.isDirectory { return .repository(shortDigest(directoryRelative)) }
        guard metadata.isRegular else { return .unreadable("git_metadata_type") }

        switch readFile(directory: directory, name: ".git", limit: 4_096) {
        case .absent:
            return .unreadable("git_metadata_changed")
        case .unreadable(let reason):
            return .unreadable(reason)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
                return .unreadable("git_metadata_malformed")
            }
            let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return .unreadable("git_metadata_malformed") }
            let directoryURL = directoryRelative.isEmpty
                ? access.url : access.url.appendingPathComponent(directoryRelative, isDirectory: true)
            let resolved = URL(fileURLWithPath: raw, relativeTo: directoryURL)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard SourcePath.relative(resolved, to: access.url) != nil else {
                return .outsideAuthorization("gitdir_outside_authorization")
            }
            return .repository(shortDigest(directoryRelative))
        }
    }

    enum ReadOutcome {
        case absent
        case unreadable(String)
        case data(Data)
    }

    /// Opens `name` inside `directory` without following symlinks, requires a
    /// regular file, bounds the read, and re-checks identity afterwards.
    static func readFile(directory: Int32, name: String, limit: Int) -> ReadOutcome {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .absent
            case ELOOP: return .unreadable("symlink")
            case EACCES, EPERM: return .unreadable("permission_denied")
            default: return .unreadable("open_failed")
            }
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { return .unreadable("stat_failed") }
        let metadata = SourceFileMetadata(before)
        guard metadata.isRegular else { return .unreadable("not_regular") }
        guard metadata.sizeBytes <= Int64(limit) else { return .unreadable("oversized") }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit, 4_096))
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress, wanted)
            }
            if count < 0 {
                return errno == EACCES ? .unreadable("permission_denied") : .unreadable("read_failed")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { return .unreadable("stat_failed") }
        let final = SourceFileMetadata(after)
        guard final.objectKey == metadata.objectKey,
              final.sizeBytes == metadata.sizeBytes,
              final.modifiedNanoseconds == metadata.modifiedNanoseconds else {
            return .unreadable("changed_during_read")
        }
        return .data(data)
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    static func shortDigest(_ value: String) -> String {
        shortDigest(Data(value.utf8))
    }

    static func shortDigest(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

// MARK: - Git (read-only)

/// One `git ls-files` snapshot for the batch.
///
/// `gitTracked` is only established when `rev-parse --show-toplevel` names the
/// authorized root itself. A scope that is not a repository top-level — including
/// a subdirectory of a larger repository — yields `unknown`, because answering
/// would require reading metadata above the authorized root. Unavailable, failed
/// and out-of-scope repositories therefore never read as `untracked`.
enum GitSnapshot {
    struct Observation {
        var tracked: EligibilityTriState
        var status: EligibilityProbeStatus
        var reason: String?
        var evidence: String?
    }

    case disabled
    case unavailable(reason: String, status: EligibilityProbeStatus)
    case loaded(paths: Set<String>)

    static func load(access: SourceRootAccess, request: EligibilityProbeRequest,
                     invocations: inout Int) -> GitSnapshot {
        guard let executable = Self.executable() else {
            return .unavailable(reason: "git_not_installed", status: .unavailable)
        }
        let root = access.url
        invocations += 1
        let top = GitReadOnly.run(executable: executable, directory: root,
                                  arguments: ["rev-parse", "--show-toplevel"],
                                  timeout: request.gitTimeout, outputLimit: 4_096)
        switch top {
        case .failure(.failed):
            // `rev-parse` failed. That is "the scope root is not a repository
            // top-level I can read", not "this host has no repository": Git also
            // exits non-zero for a refused or unreadable repository, and the two
            // would be indistinguishable without reading its stderr.
            return .unavailable(reason: "git_toplevel_unavailable", status: .unavailable)
        case .failure(let failure):
            return .unavailable(reason: failure.rawValue, status: .failed)
        case .success(let output):
            let reported = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reported.isEmpty else {
                return .unavailable(reason: "git_no_toplevel", status: .failed)
            }
            let topURL = URL(fileURLWithPath: reported).standardizedFileURL.resolvingSymlinksInPath()
            guard topURL.path == root.path else {
                return .unavailable(reason: "repository_outside_authorization", status: .outsideAuthorization)
            }
        }

        invocations += 1
        let listing = GitReadOnly.run(executable: executable, directory: root,
                                      arguments: ["ls-files", "-z", "--", "."],
                                      timeout: request.gitTimeout,
                                      outputLimit: request.gitOutputLimitBytes)
        switch listing {
        case .failure(let failure):
            return .unavailable(reason: failure.rawValue, status: .failed)
        case .success(let output):
            let paths = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            return .loaded(paths: Set(paths))
        }
    }

    func observation(for relativePath: String) -> Observation {
        switch self {
        case .disabled:
            return Observation(tracked: .unknown, status: .notChecked, reason: "probe_disabled", evidence: nil)
        case .unavailable(let reason, let status):
            return Observation(tracked: .unknown, status: status, reason: reason, evidence: nil)
        case .loaded(let paths):
            let tracked = paths.contains(relativePath)
            return Observation(tracked: tracked ? .yes : .no, status: .confirmed,
                               reason: tracked ? "tracked" : "untracked",
                               evidence: "index=\(paths.count)")
        }
    }

    static func executable() -> URL? {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

enum GitReadOnly {
    enum Failure: String, Error, Equatable {
        case timedOut = "git_timeout"
        case cancelled = "cancelled"
        case outputLimit = "git_output_limit"
        case failed = "git_failed"
    }

    /// Runs Git with a fixed executable, no shell, a scrubbed environment and a
    /// ceiling at the authorized root, so it never walks into a parent directory.
    /// Only read-only subcommands are ever passed by this module.
    static func run(executable: URL, directory: URL, arguments: [String],
                    timeout: Duration, outputLimit: Int) -> Result<Data, Failure> {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = [
            "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "safe.directory=\(directory.path)",
        ] + arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSTemporaryDirectory(),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_CEILING_DIRECTORIES": directory.path,
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GIT_SSH_COMMAND": "/usr/bin/false",
            "LC_ALL": "C",
        ]
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(.failed)
        }

        // The read below blocks until the child writes or exits, so the deadline
        // is enforced by terminating the child rather than by polling.
        let killed = GitReadOnly.Marker()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) {
            if process.isRunning {
                killed.set()
                process.terminate()
            }
        }

        var collected = Data()
        let handle = standardOutput.fileHandleForReading
        while true {
            if Task.isCancelled {
                if process.isRunning { process.terminate() }
                return .failure(.cancelled)
            }
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            if collected.count + chunk.count > outputLimit {
                if process.isRunning { process.terminate() }
                return .failure(.outputLimit)
            }
            collected.append(chunk)
        }
        process.waitUntilExit()
        if killed.isSet { return .failure(.timedOut) }
        guard process.terminationStatus == 0 else { return .failure(.failed) }
        return .success(collected)
    }

    /// A one-way flag shared with the watchdog.
    final class Marker: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
