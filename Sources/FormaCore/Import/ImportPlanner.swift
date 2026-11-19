import Foundation

/// One record of a dry-run import plan.
public struct ImportPlanRow: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let relativePath: String
    public let databaseName: String?
    public let groupPath: [String]
    public let targetResolved: Bool
    public let hydrationPending: Bool
    public let verdict: ImportPreflightVerdict
    public let codes: [ImportPreflightCode]
    public let details: [String]

    public init(sourceID: UUID, relativePath: String, databaseName: String?, groupPath: [String],
                targetResolved: Bool, hydrationPending: Bool, verdict: ImportPreflightVerdict,
                codes: [ImportPreflightCode], details: [String]) {
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.databaseName = databaseName
        self.groupPath = groupPath
        self.targetResolved = targetResolved
        self.hydrationPending = hydrationPending
        self.verdict = verdict
        self.codes = codes
        self.details = details
    }
}

/// What an Alpha user may look at before anything is written.
///
/// A plan is a *dry run by construction*: it carries no authorization it did not
/// receive, its target facts are either observed or explicitly marked
/// unobserved, and `writesInThisBuild` is a constant `false` so no view can
/// present the plan as an executed import.
public struct ImportPlan: Codable, Sendable, Equatable {
    public let manifestRevision: Int
    public let profileID: String
    public let schemaVersion: String
    /// Where the source facts came from. `scan` means "the last scan of this
    /// source"; it is not a fresh read of every byte.
    public let observation: String
    public let targetObserved: Bool
    public let rows: [ImportPlanRow]
    public let generatedAt: Date

    /// This build has no write path at all. Stated as data, not as a UI flag, so
    /// an exported plan cannot be mistaken for an approval either.
    public var writesInThisBuild: Bool { false }

    public var passes: Int { rows.filter { $0.verdict == .pass }.count }
    public var blocked: Int { rows.filter { $0.verdict == .blocked }.count }
    public var deferred: Int { rows.filter { $0.verdict == .deferred }.count }

    /// Codes that occur at least once, with how many rows carry them. This is
    /// what a person reads to answer "why can nothing be imported?".
    public var codeCounts: [(code: ImportPreflightCode, count: Int)] {
        var counts: [ImportPreflightCode: Int] = [:]
        for row in rows {
            for code in Set(row.codes) { counts[code, default: 0] += 1 }
        }
        return counts.sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .map { (code: $0.key, count: $0.value) }
    }

    public init(manifestRevision: Int, profileID: String, schemaVersion: String, observation: String,
                targetObserved: Bool, rows: [ImportPlanRow], generatedAt: Date) {
        self.manifestRevision = manifestRevision
        self.profileID = profileID
        self.schemaVersion = schemaVersion
        self.observation = observation
        self.targetObserved = targetObserved
        self.rows = rows
        self.generatedAt = generatedAt
    }
}

/// Builds the Alpha dry run from a manifest. Pure apart from reading file
/// metadata: it never opens a document body, never sends a request and never
/// touches DEVONthink.
public enum ImportPlanner {
    /// The facts a plan is built from, kept separate so a caller can state them.
    public struct Observations: Sendable {
        public let sourceRoot: URL?
        public let listing: SourceListing?

        public init(sourceRoot: URL?, listing: SourceListing?) {
            self.sourceRoot = sourceRoot
            self.listing = listing
        }
    }

    /// - Parameters:
    ///   - targetObserved: `false` in this build. Nothing here can ask DEVONthink
    ///     whether a group exists, so the target is reported as unresolved rather
    ///     than as missing.
    public static func plan(manifest: Manifest, profile: MappingProfile,
                            observations: Observations,
                            authorization: ImportAuthorization?,
                            capability: ImportCapabilityFacts = .init(writeToolsAvailable: false,
                                                                      readbackAvailable: false),
                            targetObserved: Bool = false,
                            now: Date = Date()) -> ImportPlan {
        let expectations = ImportExpectations(profileID: profile.profileID,
                                              profileVersion: profile.profileVersion,
                                              schemaVersion: profile.schemaVersion)
        let listingBySource = Dictionary(uniqueKeysWithValues:
            (observations.listing?.entries ?? []).map { ($0.id, $0) })

        let rows = manifest.entries.map { entry -> ImportPlanRow in
            let observed = observe(entry: entry,
                                   listingEntry: listingBySource[entry.sourceID],
                                   sourceRoot: observations.sourceRoot)
            let input = ImportPreflightInput(
                entry: entry, manifest: manifest.envelope, expectations: expectations,
                authorization: authorization,
                source: observed,
                target: ImportTargetFacts(exists: false, writable: false, observed: targetObserved),
                capability: capability,
                // No digest was recorded for this build's plans: the scan stores
                // fingerprints, not content hashes, and claiming one would be a
                // false statement about what was verified.
                expectedSHA256: nil,
                now: now)
            let clearance = ImportPreflight.evaluate(input)
            return ImportPlanRow(sourceID: entry.sourceID,
                                 relativePath: entry.relativePath,
                                 databaseName: entry.target.databaseName,
                                 groupPath: entry.target.groupPath,
                                 targetResolved: entry.target.resolved,
                                 hydrationPending: observed.hydrationPending,
                                 verdict: clearance.verdict,
                                 codes: clearance.failures.map(\.code),
                                 details: clearance.failures.map(\.detail))
        }

        return ImportPlan(manifestRevision: manifest.envelope.revision,
                          profileID: manifest.envelope.profileID,
                          schemaVersion: manifest.envelope.schemaVersion,
                          observation: observations.listing == nil ? "manifest only" : "scan",
                          targetObserved: targetObserved,
                          rows: rows,
                          generatedAt: now)
    }

    /// Metadata only: `stat` for existence and the dataless flag. File bodies are
    /// never opened, so building a plan cannot materialise a cloud placeholder.
    static func observe(entry: ManifestEntry, listingEntry: SourceEntry?,
                        sourceRoot: URL?) -> ImportSourceFacts {
        guard let listingEntry else {
            // The last scan did not produce this record. Saying "missing" is
            // accurate about the observation, and it prevents a plan from
            // pretending the source is still the one the manifest was built from.
            return ImportSourceFacts(state: .missing, authorized: false, readable: false,
                                     hydrationPending: false,
                                     snapshotFingerprint: entry.snapshotFingerprint, sha256: nil)
        }
        var present = true
        var hydrationPending = listingEntry.hydrationPending
        if let sourceRoot {
            let url = sourceRoot.appendingPathComponent(entry.relativePath)
            if let metadata = try? SourceFileMetadata.read(url) {
                present = true
                hydrationPending = metadata.isHydrationPending
            } else {
                present = false
            }
        }
        return ImportSourceFacts(state: present ? .present : .missing,
                                 authorized: present, readable: present,
                                 hydrationPending: present && hydrationPending,
                                 snapshotFingerprint: listingEntry.snapshotFingerprint,
                                 sha256: nil,
                                 byteCount: listingEntry.sizeBytes)
    }
}
