import Foundation

/// The reviewed Few-shot pack sent with a mapping request.
///
/// SPEC §6.2 fixes what may enter: reviewed, redacted or synthetic examples
/// only, never the full historical ledger and never an unreviewed model output.
/// The pack is data with a version, so a change to it changes
/// `case_pack_version` and forces revalidation of the manifests that cite it.
public struct CasePack: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case positive, negative, conflict, refusal
        }

        public enum EvidenceLevel: String, Codable, Sendable {
            case contentVerified = "content_verified"
            case filenamePathOnly = "filename_path_only"
            case historicalLabelOnly = "historical_label_only"
            case adjudicationPending = "adjudication_pending"
        }

        public enum Redaction: String, Codable, Sendable {
            case synthetic, reviewed
        }

        public struct Citation: Codable, Sendable, Equatable, Hashable {
            public let label: String
            public let excerpt: String
        }

        public struct Input: Codable, Sendable, Equatable {
            public let redactedRelativePath: String
            public let redactedFilename: String
            public let contextSummary: String?
            public let citations: [Citation]

            enum CodingKeys: String, CodingKey {
                case redactedRelativePath = "redacted_relative_path"
                case redactedFilename = "redacted_filename"
                case contextSummary = "context_summary", citations
            }
        }

        public struct Expected: Codable, Sendable, Equatable {
            public let state: DecisionState
            public let documentCategory: String?
            public let documentType: String?
            public let metadata: MetadataValues

            enum CodingKeys: String, CodingKey {
                case state, documentCategory = "document_category", documentType = "document_type", metadata
            }
        }

        public struct Review: Codable, Sendable, Equatable {
            public let status: Status
            public let redaction: Redaction
            public let reviewerRole: String?

            public enum Status: String, Codable, Sendable {
                case accepted, pending, rejected
            }

            enum CodingKeys: String, CodingKey {
                case status, redaction, reviewerRole = "reviewer_role"
            }
        }

        public let caseID: String
        public let kind: Kind
        public let scenario: String
        public let profiles: [String]
        public let input: Input
        public let expected: Expected
        public let whyNot: [String]
        public let evidenceLevel: EvidenceLevel
        public let sourceVersion: String
        public let review: Review

        enum CodingKeys: String, CodingKey {
            case caseID = "case_id", kind, scenario, profiles, input, expected
            case whyNot = "why_not", evidenceLevel = "evidence_level", sourceVersion = "source_version"
            case review
        }

        /// Only an accepted, synthetic-or-reviewed case may reach a prompt. A
        /// pending or rejected case stays in the file as audit history.
        public var isAdmissible: Bool {
            review.status == .accepted && (review.redaction == .synthetic || review.redaction == .reviewed)
        }
    }

    public let schemaVersion: String
    public let id: String
    public let version: String
    public var cases: [Sample]

    init(schemaVersion: String, id: String, version: String, cases: [Sample]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.cases = cases
    }

    public var versionKey: String { "\(id)@\(version)" }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, version, cases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(String.self, forKey: .version)
        cases = try container.decode([Sample].self, forKey: .cases)
        try Self.check(self)
    }

    static func check(_ pack: CasePack) throws {
        guard pack.schemaVersion == "1.0" else { throw FormaError.incompatible }
        guard pack.cases.count >= 20, pack.cases.count <= 30 else { throw FormaError.incompatible }
        guard Set(pack.cases.map(\.caseID)).count == pack.cases.count else { throw FormaError.incompatible }
        guard pack.cases.allSatisfy(\.isAdmissible) else {
            // An unreviewed or unredacted example in a shipped pack is a privacy
            // and quality defect, not a warning.
            throw FormaError.incompatible
        }
        // SPEC §6.2: the pack must teach both profiles and the counter-example
        // kinds, otherwise "20-30 cases" is satisfied by easy positives alone.
        let kinds = Set(pack.cases.map(\.kind))
        guard kinds.contains(.negative), kinds.contains(.conflict) || kinds.contains(.refusal) else {
            throw FormaError.incompatible
        }
        let profiles = Set(pack.cases.flatMap(\.profiles))
        guard profiles.contains(ProjectArchiveContract.id), profiles.contains(VendorLibraryContract.id) else {
            throw FormaError.incompatible
        }
        // Content-verified evidence carries the pack; a pack built mostly from
        // historical labels would teach the model to copy labels.
        let verified = pack.cases.filter { $0.evidenceLevel == .contentVerified }.count
        guard verified * 2 >= pack.cases.count else { throw FormaError.incompatible }
    }

    /// The pack has to teach the traps the profiles declare. `check` above can
    /// only count kinds and profile ids: a pack of twenty negatives that never
    /// refuses a category would clear every guard there while teaching nothing
    /// about the ways the historical archive actually went wrong.
    ///
    /// The requirement is read from the profiles rather than invented here. A
    /// category has to be refused by a counter-example for a profile exactly
    /// when that profile's own counter-example text names it, so a profile that
    /// declares a new trap forces the pack to teach it, and a profile that names
    /// none - the Vendor Library's traps are about project binding, not
    /// categories - asks for nothing.
    public static func untaughtCategories(in pack: CasePack,
                                          profiles: [MappingProfile]) -> [String: [String]] {
        var missing: [String: [String]] = [:]
        for profile in profiles {
            let named = profile.categories.map(\.identifier).filter { identifier in
                profile.counterExamples.contains { $0.contains(identifier) }
            }
            let refused = pack.cases
                .filter { $0.profiles.contains(profile.profileID) && $0.kind != .positive }
                .flatMap(\.whyNot)
            let gaps = named.filter { identifier in !refused.contains { $0.contains(identifier) } }
            if !gaps.isEmpty { missing[profile.profileID] = gaps }
        }
        return missing
    }

    /// `check` plus the trap coverage the profiles declare.
    public static func check(_ pack: CasePack, teaching profiles: [MappingProfile]) throws {
        try check(pack)
        guard untaughtCategories(in: pack, profiles: profiles).isEmpty else { throw FormaError.incompatible }
    }

    /// The shipped pack against the shipped profiles, which is the only pair
    /// that has to agree. Callers that load a custom profile pass it in.
    public static func checkShippedTeaching() throws {
        try check(shipped(), teaching: [try MappingProfile.projectArchive(), try MappingProfile.vendorLibrary()])
    }

    /// The cases a request may use for one profile, in a deterministic order.
    ///
    /// Selection is bounded so a prompt cannot grow with the archive, and it is
    /// stable so the same pack version always produces the same input digest.
    public func selected(for profile: MappingProfile, limit: Int = 24) -> [Sample] {
        let matching = cases.filter { $0.profiles.contains(profile.profileID) }
        // Counter-examples and refusals are the reason the pack exists: keep
        // them when the budget is tight, then fill with content-verified
        // positives ordered by case id.
        let priority: (Sample) -> Int = { sample in
            switch sample.kind {
            case .negative: 0
            case .conflict: 1
            case .refusal: 2
            case .positive: 3
            }
        }
        return matching
            .sorted { (priority($0), $0.caseID) < (priority($1), $1.caseID) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public static func shipped() throws -> CasePack {
        guard let url = Bundle.module.url(forResource: "forma-governance-cases.v1", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw FormaError.unavailable }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> CasePack {
        // Schema first, then types: the same order the provider response uses.
        try ArtifactSchemaValidator.casePack.validate(data)
        return try JSONDecoder().decode(CasePack.self, from: data)
    }
}
