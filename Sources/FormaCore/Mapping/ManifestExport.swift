import CryptoKit
import Foundation

/// The exported form of one manifest revision and the offline checks that make
/// it verifiable without a provider, a Keychain or a network.
///
/// PLAN §7.3 requires the export to be re-checkable offline, and SPEC §6.3
/// requires the artifact to bind the versions that produced it. The bundle is
/// therefore self-describing: the manifest, the validation report, the
/// exceptions, the evidence rows it cites, a version summary and a digest list.
/// Re-running the checks against those files must reproduce the same verdict,
/// which is what lets a reviewer confirm a claim days later on another machine.
public enum ManifestExport {
    public struct Summary: Codable, Sendable, Equatable {
                public let manifestID: String
                public let revision: Int
                public let entries: Int
                public let validated: Int
                public let hold: Int
                public let unknown: Int
                public let eligible: Int
                public let files: [String]
                public let digests: [String: String]
    }

    public struct Revalidation: Codable, Sendable, Equatable {
        public let manifestID: String
        public let revision: Int
                /// The stored artifact's own checks: schema, version binding,
                /// evidence presence and policy. Independent of any live file.
                public let artifactConsistent: Bool
                public let violations: [ValidationViolation]
                public let missingEvidence: [String]
                public let digestMismatch: [String]
                public let grantsExecution: Bool
    }

    // The bundle's on-disk names. Two are public because a caller outside this
    // module now has to open those files by name: the app's bundle reader, and
    // its "where do I look up this evidence id" notice. The rest stay internal
    // until something outside needs them - a file-format convention published
    // before it has a consumer is an API surface nothing checks.
    public static let manifestFile = "manifest.json"
    static let reportFile = "validation-report.json"
    static let exceptionsFile = "exceptions.json"
    public static let evidenceFile = "evidence.json"
    static let versionsFile = "versions.json"
    static let digestsFile = "digests.json"
    static let redactedDirectory = "redacted"

    /// Writes the bundle and returns exactly what was written.
    ///
    /// The directory must not already contain a manifest of the same revision:
    /// an export is evidence, so overwriting one silently would let two
    /// contradictory "facts" share a path.
    public static func export(manifest: Manifest, evidence: [EvidenceRecord], to directory: URL,
                              redaction: RedactionPlan? = nil) throws -> Summary {
        let encoder = FormaJSON.encoder(pretty: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(manifest.envelope.manifestID.sourceKey, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let manifestData = try encoder.encode(manifest)
        let reportData = try encoder.encode(manifest.report)
        let exceptions = Exceptions(extract: manifest)
        let exceptionsData = try encoder.encode(exceptions)
        // Only the evidence the manifest actually cites travels with it: the
        // registry may hold far more, and an export is not a document dump.
        let cited = Set(manifest.entries.flatMap { entry in entry.fields.flatMap(\.evidenceIDs) })
        let included = evidence.filter { cited.contains($0.id) }.sorted { $0.id < $1.id }
        let evidenceData = try encoder.encode(included)
        let versions = versionSummary(manifest: manifest, evidence: included)
        let versionsData = try encoder.encode(versions)

        let files = [manifestFile, reportFile, exceptionsFile, evidenceFile, versionsFile]
        let payloads = [manifestData, reportData, exceptionsData, evidenceData, versionsData]
        var digests: [String: String] = [:]
        for (name, data) in zip(files, payloads) {
            try write(data, to: target.appendingPathComponent(name))
            digests[name] = SHA256.hash(data: data).hexadecimalDigest
        }
        let digestsData = try encoder.encode(digests)
        try write(digestsData, to: target.appendingPathComponent(digestsFile))
        digests[digestsFile] = SHA256.hash(data: digestsData).hexadecimalDigest

        // The shareable copy exists only when the caller supplied a plan: an
        // unredacted "shareable" file would be a leak with a misleading name.
        if let redaction {
            let shareDirectory = target.appendingPathComponent(redactedDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let share = try redacted(manifest: manifest, redaction: redaction)
            try write(share, to: shareDirectory.appendingPathComponent(manifestFile))
        }

        return Summary(
            manifestID: manifest.envelope.manifestID.sourceKey, revision: manifest.envelope.revision,
            entries: manifest.entries.count, validated: manifest.report.counts.validated,
            hold: manifest.report.counts.hold, unknown: manifest.report.counts.unknown,
            eligible: manifest.eligibleCount, files: files + [digestsFile], digests: digests
        )
    }

    /// Re-checks a written bundle without touching a provider or a source file.
    public static func revalidate(at url: URL) throws -> Revalidation {
        let manifestData = try Data(contentsOf: url.appendingPathComponent(manifestFile))
        var violations = try ArtifactSchemaValidator.manifest.violations(manifestData).map(ValidationViolation.init)
        let manifest = try FormaJSON.decode(Manifest.self, from: manifestData)

        let evidenceData = try Data(contentsOf: url.appendingPathComponent(evidenceFile))
        let evidence = try FormaJSON.decode([EvidenceRecord].self, from: evidenceData)
        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })

        var missing: [String] = []
        for entry in manifest.entries {
            for outcome in entry.fields {
                for id in outcome.evidenceIDs where byID[id] == nil {
                    missing.append(id)
                }
            }
        }
        if !missing.isEmpty {
            violations.append(ValidationViolation(code: "evidence_not_found", instancePath: evidenceFile,
                                                  detail: "\(missing.count) cited evidence rows are absent from the bundle."))
        }
        // A bundle that claims execution authority is corrupt by definition.
        if manifest.envelope.grantsExecution {
            violations.append(ValidationViolation(code: "execution_authority", instancePath: manifestFile,
                                                  detail: "No exported manifest may grant execution."))
        }
        for entry in manifest.entries where entry.eligibleForAutoExecution && entry.state != .validated {
            violations.append(ValidationViolation(code: "eligibility_state", instancePath: entry.relativePath,
                                                  detail: "Only a validated entry may be eligible."))
        }

        var mismatched: [String] = []
        let recorded = (try? FormaJSON.decode([String: String].self,
                                              from: Data(contentsOf: url.appendingPathComponent(digestsFile)))) ?? [:]
        for (name, expected) in recorded where name != digestsFile {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(name)) else {
                mismatched.append(name)
                continue
            }
            if SHA256.hash(data: data).hexadecimalDigest != expected { mismatched.append(name) }
        }

        return Revalidation(manifestID: manifest.envelope.manifestID.sourceKey,
                            revision: manifest.envelope.revision,
                            artifactConsistent: violations.isEmpty,
                            violations: violations, missingEvidence: Array(Set(missing)).sorted(),
                            digestMismatch: mismatched.sorted(),
                            grantsExecution: manifest.envelope.grantsExecution)
    }

    /// The exception list the interface and the export both show: one row per
    /// blocked entry with the reason the program recorded, not the model's.
    public struct Exceptions: Codable, Sendable, Equatable {
        public struct Row: Codable, Sendable, Equatable {
            public let sourceID: String
            public let relativePath: String
            public let state: String
            public let reason: String
            public let codes: [String]

            enum CodingKeys: String, CodingKey {
                case sourceID, relativePath, state, reason, codes
            }
        }

        public let rows: [Row]

        public init(extract manifest: Manifest) {
            let byPath = Dictionary(grouping: manifest.report.allViolations) { $0.instancePath }
            rows = manifest.entries.filter { $0.state == .hold || $0.state == .unknown || $0.state == .invalidated }
                .sorted { $0.relativePath < $1.relativePath }
                .map { entry in
                    Row(sourceID: entry.sourceID.sourceKey, relativePath: entry.relativePath,
                        state: entry.state.rawValue,
                        reason: entry.invalidatedReason ?? entry.fields.first { $0.status == .conflict }?.field.rawValue
                            ?? "evidence_incomplete",
                        codes: Array(Set((byPath[entry.relativePath] ?? []).map(\.code))).sorted())
                }
        }
    }

    public struct VersionSummary: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let profileID: String
        public let profileVersion: String
        public let casePackID: String
        public let casePackVersion: String
        public let promptVersion: String
        public let extractorVersion: String
        public let redactionVersion: String?
        public let modelProvider: String
        public let modelID: String?
        public let contextRevision: Int
        public let inputDigest: String
        public let contextDigest: String
        public let evidenceCount: Int
        public let evidenceDigest: String
    }

    private static func versionSummary(manifest: Manifest, evidence: [EvidenceRecord]) -> VersionSummary {
        var hasher = SHA256()
        for record in evidence {
            hasher.update(data: Data("\(record.id)|\(record.snapshotRevision)|\(record.excerpt?.count ?? 0)\n".utf8))
        }
        return VersionSummary(
            schemaVersion: manifest.schemaVersion, profileID: manifest.envelope.profileID,
            profileVersion: manifest.envelope.profileVersion, casePackID: manifest.envelope.casePackID,
            casePackVersion: manifest.envelope.casePackVersion, promptVersion: manifest.envelope.promptVersion,
            extractorVersion: manifest.envelope.extractorVersion,
            redactionVersion: manifest.envelope.redactionVersion,
            modelProvider: manifest.envelope.modelProvider, modelID: manifest.envelope.modelID,
            contextRevision: manifest.envelope.contextRevision, inputDigest: manifest.envelope.inputDigest,
            contextDigest: manifest.envelope.contextDigest, evidenceCount: evidence.count,
            evidenceDigest: hasher.finalize().hexadecimalDigest
        )
    }

    private static func redacted(manifest: Manifest, redaction: RedactionPlan) throws -> Data {
        var copy = manifest
        for index in copy.entries.indices {
            let entry = copy.entries[index]
            copy.entries[index].relativePath = redaction.redact(path: entry.relativePath)
            copy.entries[index].providerReasoning = entry.providerReasoning.map { redaction.redact(text: $0) }
            // The target is where the project name lives a second time, and the
            // association basis a third: redacting the relative path alone
            // leaves both intact, which is the leak this copy exists to avoid.
            copy.entries[index].target = ManifestTarget(
                databaseName: entry.target.databaseName.map { redaction.redact(text: $0) },
                groupPath: entry.target.groupPath.map { redaction.redact(path: $0) },
                resolved: entry.target.resolved)
            copy.entries[index].associations = entry.associations.map { link in
                ManifestAssociation(kind: link.kind, sourceID: link.sourceID,
                                    basis: redaction.redact(text: link.basis), evidenceIDs: link.evidenceIDs)
            }
            var values = MetadataValues.allUnknown
            for field in MetadataFieldID.allCases {
                values[field] = entry.metadata[field].map { redaction.redact(text: $0) }
            }
            copy.entries[index].metadata = values
        }
        return try FormaJSON.encoder(pretty: true).encode(copy)
    }

    private static func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try? Data(contentsOf: url)
            // Rewriting identical bytes is harmless; rewriting different bytes
            // would replace one piece of evidence with another.
            if existing != data { throw FormaError.sourceChanged }
            return
        }
        try data.write(to: url, options: .atomic)
        // The bundle holds business content, so a file that cannot be closed
        // to group and world is not exported at all: a silently world-readable
        // evidence file is precisely the failure this function exists to avoid.
        // The containing directory is created 0700, so only the owner can reach
        // the file in the interval between the write and this call.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
