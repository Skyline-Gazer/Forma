import CryptoKit
import Foundation

/// Per-record import preflight (PLAN §10.1).
///
/// Everything here is a fact the caller supplies: no filesystem access, no MCP,
/// no clock of its own. That keeps the rules testable and keeps the executor
/// from quietly re-deriving facts the scan already established.
///
/// The verdict is per record on purpose. One unreadable file must not stop the
/// other 9,999; it becomes a `deferred` row that is retried later, not a reason
/// to abandon the batch.

// MARK: - Authorization

/// The authority to import, kept separate from the manifest.
///
/// `ManifestEnvelope.grantsExecution` is always `false` in this product, and a
/// manifest claiming otherwise is a contract violation rather than a grant.
/// Authorization is therefore its own object, supplied by the Owner-facing
/// flow, and this phase never manufactures one.
public struct ImportAuthorization: Codable, Sendable, Equatable {
    public let databaseName: String
    /// Groups under this prefix are in scope; an empty prefix means the database
    /// root, which is still an explicit decision.
    public let groupPrefix: [String]
    public let authorizedBy: String
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(databaseName: String, groupPrefix: [String], authorizedBy: String,
                issuedAt: Date, expiresAt: Date? = nil) {
        self.databaseName = databaseName
        self.groupPrefix = groupPrefix
        self.authorizedBy = authorizedBy
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// Digest of the scope, never of a credential: the ledger records what was
    /// authorized, not how.
    public var digest: String {
        let canonical = "v1|\(databaseName)|\(groupPrefix.joined(separator: "/"))"
            + "|\(authorizedBy)|\(issuedAt.timeIntervalSince1970)|\(expiresAt?.timeIntervalSince1970 ?? -1)"
        return SHA256.hash(data: Data(canonical.utf8)).hexadecimalDigest
    }

    public func covers(database: String, groupPath: [String]) -> Bool {
        guard database == databaseName else { return false }
        guard !groupPrefix.isEmpty else { return true }
        guard groupPath.count >= groupPrefix.count else { return false }
        return Array(groupPath.prefix(groupPrefix.count)) == groupPrefix
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}

// MARK: - Facts

public struct ImportSourceFacts: Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case present, missing
    }

    public let state: State
    public let authorized: Bool
    public let readable: Bool
    public let hydrationPending: Bool
    /// The fingerprint the scan recorded for the bytes on disk now.
    public let snapshotFingerprint: String
    /// Verified digest of the bytes this run read; nil means unverified.
    public let sha256: String?
    /// The read session that produced this observation. A recovery cannot
    /// proceed without it: the session is part of the source binding.
    public let readSessionID: String?
    /// Byte count observed in this session; must match the binding.
    public let byteCount: Int64?

    public init(state: State, authorized: Bool, readable: Bool, hydrationPending: Bool,
                snapshotFingerprint: String, sha256: String?,
                readSessionID: String? = nil, byteCount: Int64? = nil) {
        self.state = state
        self.authorized = authorized
        self.readable = readable
        self.hydrationPending = hydrationPending
        self.snapshotFingerprint = snapshotFingerprint
        self.sha256 = sha256
        self.readSessionID = readSessionID
        self.byteCount = byteCount
    }
}

public struct ImportTargetFacts: Sendable, Equatable {
    public let exists: Bool
    public let writable: Bool
    public let availableBytes: Int64?
    public let requiredBytes: Int64?

    public init(exists: Bool, writable: Bool, availableBytes: Int64? = nil,
                requiredBytes: Int64? = nil) {
        self.exists = exists
        self.writable = writable
        self.availableBytes = availableBytes
        self.requiredBytes = requiredBytes
    }
}

public struct ImportCapabilityFacts: Sendable, Equatable {
    public let writeToolsAvailable: Bool
    public let readbackAvailable: Bool

    public init(writeToolsAvailable: Bool, readbackAvailable: Bool) {
        self.writeToolsAvailable = writeToolsAvailable
        self.readbackAvailable = readbackAvailable
    }
}

/// The run's own identity, as the import must match it.
public struct ImportExpectations: Sendable, Equatable {
    public let profileID: String
    public let profileVersion: String
    public let schemaVersion: String

    public init(profileID: String, profileVersion: String, schemaVersion: String) {
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.schemaVersion = schemaVersion
    }
}

public struct ImportPreflightInput: Sendable {
    public let entry: ManifestEntry
    public let manifest: ManifestEnvelope
    public let expectations: ImportExpectations
    public let authorization: ImportAuthorization?
    public let source: ImportSourceFacts
    public let target: ImportTargetFacts
    public let capability: ImportCapabilityFacts
    /// The digest the manifest's evidence established for this file, when one was
    /// recorded. A mismatch invalidates the mapping; it is not a warning.
    public let expectedSHA256: String?
    public let now: Date

    public init(entry: ManifestEntry, manifest: ManifestEnvelope,
                expectations: ImportExpectations, authorization: ImportAuthorization?,
                source: ImportSourceFacts, target: ImportTargetFacts,
                capability: ImportCapabilityFacts, expectedSHA256: String?, now: Date) {
        self.entry = entry
        self.manifest = manifest
        self.expectations = expectations
        self.authorization = authorization
        self.source = source
        self.target = target
        self.capability = capability
        self.expectedSHA256 = expectedSHA256
        self.now = now
    }
}

// MARK: - Result

public enum ImportPreflightCode: String, Codable, Sendable, CaseIterable {
    case sourceUnauthorized = "source_unauthorized"
    case sourceMissing = "source_missing"
    case sourceChanged = "source_changed"
    case sourceUnreadable = "source_unreadable"
    case hydrationPending = "hydration_pending"
    case sourceSHAMismatch = "source_sha_mismatch"
    case entryNotEligible = "entry_not_eligible"
    case entryInvalidated = "entry_invalidated"
    case manifestNotValidated = "manifest_not_validated"
    case targetUnresolved = "target_unresolved"
    case targetMissing = "target_missing"
    case targetOutsideAuthorization = "target_outside_authorization"
    case targetNotWritable = "target_not_writable"
    case insufficientSpace = "insufficient_space"
    case capabilityMissing = "capability_missing"
    case authorizationMissing = "authorization_missing"
    case authorizationExpired = "authorization_expired"
    case profileMismatch = "profile_mismatch"
    case schemaMismatch = "schema_mismatch"

    /// A transient failure is retried later; it is not a skip and not a failure
    /// of the record. PLAN §10.1 names timeout, offline and permission.
    public var isTransient: Bool {
        switch self {
        case .sourceUnauthorized, .sourceUnreadable, .hydrationPending,
             .insufficientSpace, .capabilityMissing:
            return true
        default:
            return false
        }
    }
}

public struct ImportPreflightFailure: Codable, Sendable, Equatable {
    public let code: ImportPreflightCode
    /// Non-sensitive: no paths, no file names, no content.
    public let detail: String

    public init(_ code: ImportPreflightCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public enum ImportPreflightVerdict: String, Codable, Sendable {
    case pass
    /// Only transient failures: keep the intent, retry later.
    case deferred
    /// At least one blocking failure: this record cannot be imported as it stands.
    case blocked
}

/// The facts a clearance is bound to.
///
/// A clearance is a permission *for one operation*, not a general "it is fine to
/// import" flag: it names the source, the snapshot, the manifest revision, the
/// target and the authorization it was decided under. A clearance for another
/// source, another snapshot or another authorization is not a permission for this
/// one, and the executor checks every component before it writes.
public struct ImportPreflightBinding: Sendable, Equatable {
    public let sourceID: UUID
    public let snapshotFingerprint: String
    public let manifestRevision: Int
    public let targetDatabase: String
    public let targetGroupPath: [String]
    /// Digest of the authorization object the decision was made under.
    public let authorizationDigest: String
    public let verdict: ImportPreflightVerdict
    public let failures: [ImportPreflightFailure]
    init(sourceID: UUID, snapshotFingerprint: String, manifestRevision: Int,
         targetDatabase: String, targetGroupPath: [String], authorizationDigest: String,
         verdict: ImportPreflightVerdict, failures: [ImportPreflightFailure]) {
        self.sourceID = sourceID
        self.snapshotFingerprint = snapshotFingerprint
        self.manifestRevision = manifestRevision
        self.targetDatabase = targetDatabase
        self.targetGroupPath = targetGroupPath
        self.authorizationDigest = authorizationDigest
        self.verdict = verdict
        self.failures = failures
    }
}

/// The result of a preflight, usable as a write permission only for the
/// operation it names.
///
/// The initializer is private on purpose: a clearance can only come from
/// `ImportPreflight.evaluate`. That is what makes "a pass" mean "the preflight
/// rules were run against these facts" instead of "someone wrote an empty
/// failure list".
public struct ImportPreflightClearance: Sendable, Equatable {
    public let binding: ImportPreflightBinding

    /// Only `ImportPreflight.evaluate` may create a clearance: the initializer
    /// is file-scoped, so neither another module nor a test can hand-write a
    /// permission.
    fileprivate init(binding: ImportPreflightBinding) {
        self.binding = binding
    }

    public var verdict: ImportPreflightVerdict { binding.verdict }
    public var failures: [ImportPreflightFailure] { binding.failures }

    public var blockingCodes: [ImportPreflightCode] {
        failures.map(\.code).filter { !$0.isTransient }
    }
}

public enum ImportPreflight {
    /// Evaluates one manifest entry. Pure: same input, same result.
    ///
    /// The returned clearance is bound to the facts this call saw; it is not a
    /// reusable permission and it says nothing about any other record.
    public static func evaluate(_ input: ImportPreflightInput) -> ImportPreflightClearance {
        var failures: [ImportPreflightFailure] = []
        let entry = input.entry

        // 1. The manifest must be a validated, non-executing revision.
        if input.manifest.state != .validated {
            failures.append(.init(.manifestNotValidated, detail: "manifest state is \(input.manifest.state.rawValue)"))
        }
        // No check for `grants_execution` here: the manifest decoder refuses a
        // manifest that claims it (`FormaError.invalidOutput`), so a value this
        // type could see is already false. Re-checking it would be dead code.
        if entry.state != .validated {
            failures.append(.init(.entryInvalidated, detail: "entry state is \(entry.state.rawValue)"))
        }
        if !entry.eligibleForAutoExecution {
            failures.append(.init(.entryNotEligible, detail: "entry is not eligible for automatic execution"))
        }

        // 2. Authorization is its own object.
        guard let authorization = input.authorization else {
            failures.append(.init(.authorizationMissing, detail: "no import authorization"))
            return ImportPreflightClearance(binding: Self.binding(input, failures: failures,
                                                                 authorizationDigest: ""))
        }
        if authorization.isExpired(at: input.now) {
            failures.append(.init(.authorizationExpired, detail: "authorization expired"))
        }
        if !authorization.covers(database: entry.target.databaseName ?? "", groupPath: entry.target.groupPath) {
            failures.append(.init(.targetOutsideAuthorization, detail: "target is outside the authorized scope"))
        }

        // 3. Profile and schema must be the ones this run was measured under.
        if input.manifest.profileID != input.expectations.profileID
            || input.manifest.profileVersion != input.expectations.profileVersion {
            failures.append(.init(.profileMismatch, detail: "manifest profile differs from the import target"))
        }
        if input.manifest.schemaVersion != input.expectations.schemaVersion {
            failures.append(.init(.schemaMismatch, detail: "manifest schema differs from the import target"))
        }

        // 4. The source must be the bytes the decision was made from.
        switch input.source.state {
        case .missing:
            failures.append(.init(.sourceMissing, detail: "source no longer exists"))
        case .present:
            if input.source.snapshotFingerprint != entry.snapshotFingerprint {
                failures.append(.init(.sourceChanged, detail: "snapshot differs from the manifest"))
            }
        }
        if !input.source.authorized {
            failures.append(.init(.sourceUnauthorized, detail: "source access was denied"))
        }
        if input.source.hydrationPending {
            failures.append(.init(.hydrationPending, detail: "source bytes are not downloaded"))
        }
        if !input.source.readable {
            failures.append(.init(.sourceUnreadable, detail: "source could not be read"))
        }
        if let expected = input.expectedSHA256, let actual = input.source.sha256, expected != actual {
            // A changed file invalidates the mapping decision; the executor must
            // not re-decide it, so this is a block rather than a retry.
            failures.append(.init(.sourceSHAMismatch, detail: "content digest differs from the recorded evidence"))
        }

        // 5. The target must be a resolved, writable, in-scope group.
        if !entry.target.resolved {
            failures.append(.init(.targetUnresolved, detail: "target group path is unresolved"))
        }
        if !input.target.exists {
            failures.append(.init(.targetMissing, detail: "target group does not exist"))
        }
        if !input.target.writable {
            failures.append(.init(.targetNotWritable, detail: "target group is not writable"))
        }
        if let available = input.target.availableBytes, let required = input.target.requiredBytes,
           required > available {
            failures.append(.init(.insufficientSpace, detail: "insufficient free space"))
        }

        // 6. Capability: both directions are required. A writer without an
        // independent reader cannot produce readback evidence.
        if !input.capability.writeToolsAvailable || !input.capability.readbackAvailable {
            failures.append(.init(.capabilityMissing, detail: "write or readback capability is unavailable"))
        }

        return ImportPreflightClearance(binding: Self.binding(input, failures: failures,
                                                              authorizationDigest: input.authorization?.digest ?? ""))
    }

    /// The binding every clearance carries: the facts the decision was made
    /// against, so a later consumer can tell whether it still applies.
    private static func binding(_ input: ImportPreflightInput, failures: [ImportPreflightFailure],
                                 authorizationDigest: String) -> ImportPreflightBinding {
        let verdict: ImportPreflightVerdict
        if failures.isEmpty {
            verdict = .pass
        } else {
            verdict = failures.contains { !$0.code.isTransient } ? .blocked : .deferred
        }
        return ImportPreflightBinding(
            sourceID: input.entry.sourceID,
            snapshotFingerprint: input.entry.snapshotFingerprint,
            manifestRevision: input.manifest.revision,
            targetDatabase: input.entry.target.databaseName ?? "",
            targetGroupPath: input.entry.target.groupPath,
            authorizationDigest: authorizationDigest,
            verdict: verdict, failures: failures)
    }
}
