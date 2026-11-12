import Foundation

/// One independently annotated reference answer.
///
/// A gold record is not a prompt example: it exists to be scored against, which
/// is why `usage` is part of the record rather than a property of the directory
/// it sits in. Two records for the same file - one few-shot, one gold - would
/// silently inflate every metric, and the only defence that survives edits is a
/// field the split check can read.
public struct GoldRecord: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case positive, negative, conflict, refusal
        case nearDuplicate = "near_duplicate"
        case templateFamily = "template_family"
        case partialEvidence = "partial_evidence"
        case adversarialWording = "adversarial_wording"
    }

    public enum ReviewStatus: String, Codable, Sendable, CaseIterable {
        case confirmed, adjudicationPending = "adjudication_pending", rejected
    }

    public enum Redaction: String, Codable, Sendable, CaseIterable {
        case synthetic, reviewed, unredacted
    }

    public enum Usage: String, Codable, Sendable, CaseIterable {
        case evaluation, fewshot, excluded
    }

    public struct Scenario: Codable, Sendable, Equatable {
        public let category: Category
        public let description: String
    }

    /// The identity of the underlying file. `sha256` is optional because a
    /// redacted record may describe material whose bytes are not in the
    /// repository; when it is absent, cluster isolation is the only lever left
    /// and the split check says so instead of assuming separation.
    public struct Source: Codable, Sendable, Equatable {
        public let projectClusterKey: String
        public let sourceUUID: String?
        public let sha256: String?
        public let redactedRelativePath: String
        public let redactedFilename: String
        public let nearDuplicateGroup: String?

        enum CodingKeys: String, CodingKey {
            case projectClusterKey = "project_cluster_key", sourceUUID = "source_uuid", sha256
            case redactedRelativePath = "redacted_relative_path", redactedFilename = "redacted_filename"
            case nearDuplicateGroup = "near_duplicate_group"
        }
    }

    /// What a correct mapping looks like. `allowedUnknownFields` names the slots
    /// where an empty prediction is right rather than a miss: a field the source
    /// genuinely does not state must not be scored as an error when the engine
    /// holds it, and must not be scored as a hit when a value is invented.
    /// Nullable slots are written as explicit nulls by `encode(to:)`: the
    /// synthesized version would omit them, and the schema's `required` list
    /// treats an absent key as a violation.
    public struct Expected: Codable, Sendable, Equatable {
        public let state: DecisionState
        public let projectReference: String?
        public let targetCategory: String?
        public let targetType: String?
        public let metadata: MetadataValues
        public let allowedUnknownFields: Set<MetadataFieldID>

        enum CodingKeys: String, CodingKey {
            case state, projectReference = "project_reference", targetCategory = "target_category"
            case target_type, metadata, allowedUnknownFields = "allowed_unknown_fields"
        }

        public init(state: DecisionState, projectReference: String?, targetCategory: String?,
                    targetType: String?, metadata: MetadataValues, allowedUnknownFields: Set<MetadataFieldID>) {
            self.state = state
            self.projectReference = projectReference
            self.targetCategory = targetCategory
            self.targetType = targetType
            self.metadata = metadata
            self.allowedUnknownFields = allowedUnknownFields
        }

        /// The three nullable slots arrive through `decodeIfPresent` of an
        /// optional, which is the only pair that tells an explicit JSON null
        /// apart from a key the writer forgot: the schema lists all of them as
        /// `required`, and a record that never stated an expected document type
        /// must not be scored as one whose document type is known to be absent.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            state = try container.decode(DecisionState.self, forKey: .state)
            projectReference = try container.decodeIfPresent(String?.self, forKey: .projectReference) ?? nil
            targetCategory = try container.decodeIfPresent(String?.self, forKey: .targetCategory) ?? nil
            targetType = try container.decodeIfPresent(String?.self, forKey: .target_type) ?? nil
            metadata = try container.decode(MetadataValues.self, forKey: .metadata)
            allowedUnknownFields = try container.decodeIfPresent(Set<MetadataFieldID>.self,
                                                                  forKey: .allowedUnknownFields) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(projectReference ?? nil, forKey: .projectReference)
            try container.encode(targetCategory ?? nil, forKey: .targetCategory)
            try container.encode(targetType ?? nil, forKey: .target_type)
            try container.encode(metadata, forKey: .metadata)
            try container.encode(Array(allowedUnknownFields).sorted(), forKey: .allowedUnknownFields)
        }
    }

    public struct Citation: Codable, Sendable, Equatable, Hashable {
        public let label: String
        public let excerpt: String
        public let locator: String?
    }

    public struct Annotation: Codable, Sendable, Equatable {
        public let annotatorCode: String
        public let annotatedOn: String
        public let basis: String

        enum CodingKeys: String, CodingKey {
            case annotatorCode = "annotator_code", annotatedOn = "annotated_on", basis
        }
    }

    /// Reviewer identity is a role code, never a name: the dataset is published
    /// as a specification and an auditable count, not as a list of employees.
    public struct Review: Codable, Sendable, Equatable {
        public let status: ReviewStatus
        public let redaction: Redaction
        public let reviewerCode: String
        public let reviewedOn: String

        enum CodingKeys: String, CodingKey {
            case status, redaction, reviewerCode = "reviewer_code", reviewedOn = "reviewed_on"
        }
    }

    public let schemaVersion: String
    public let recordID: String
    public let datasetRevision: String
    public let profiles: [String]
    public let scenario: Scenario
    public let source: Source
    public let expected: Expected
    public let citations: [Citation]
    public let annotation: Annotation
    public let review: Review
    public let usage: Usage

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", recordID = "record_id", datasetRevision = "dataset_revision"
        case profiles, scenario, source, expected, citations, annotation, review, usage
    }

    public init(schemaVersion: String = "1.0", recordID: String, datasetRevision: String, profiles: [String],
                scenario: Scenario, source: Source, expected: Expected, citations: [Citation],
                annotation: Annotation, review: Review, usage: Usage) throws {
        self.schemaVersion = schemaVersion
        self.recordID = recordID
        self.datasetRevision = datasetRevision
        self.profiles = profiles
        self.scenario = scenario
        self.source = source
        self.expected = expected
        self.citations = citations
        self.annotation = annotation
        self.review = review
        self.usage = usage
        // The rules the decoder applies run here too: a record assembled in
        // code - a fixture generator, or whatever writes a new sample - must not
        // be a second class of input that skips the privacy and rejection checks.
        try Self.check(self)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        recordID = try container.decode(String.self, forKey: .recordID)
        datasetRevision = try container.decode(String.self, forKey: .datasetRevision)
        profiles = try container.decode([String].self, forKey: .profiles)
        scenario = try container.decode(Scenario.self, forKey: .scenario)
        source = try container.decode(Source.self, forKey: .source)
        expected = try container.decode(Expected.self, forKey: .expected)
        citations = try container.decode([Citation].self, forKey: .citations)
        annotation = try container.decode(Annotation.self, forKey: .annotation)
        review = try container.decode(Review.self, forKey: .review)
        usage = try container.decode(Usage.self, forKey: .usage)
        try Self.check(self)
    }

    /// Rules that the JSON Schema cannot express, in the same spirit as
    /// `CasePack.check`: an unreviewed or unredacted record is a defect, not a
    /// warning, and an answer with nothing behind it is not a reference answer.
    static func check(_ record: GoldRecord) throws {
        guard record.schemaVersion == "1.0" else { throw FormaError.incompatible }
        // A rejected record may stay in the tree as audit history, but it must
        // not claim evaluation use - that combination is what would put a known
        // wrong answer into a denominator.
        guard !(record.review.status == .rejected && record.usage == .evaluation) else {
            throw FormaError.incompatible
        }
        guard record.review.redaction == .synthetic || record.review.redaction == .reviewed else {
            throw FormaError.incompatible
        }
        guard !record.citations.isEmpty else { throw FormaError.incompatible }
        guard record.profiles.count == Set(record.profiles).count else { throw FormaError.incompatible }
    }

    /// Counts in a metric denominator: confirmed, marked for evaluation, and
    /// carrying at least one citation. `adjudication_pending` is deliberately
    /// absent - PLAN §8.1 excludes disputed records from the denominator while
    /// requiring the excluded volume to be reported, and `GoldDataset` does that
    /// through `pendingAdjudication`.
    public var isCountable: Bool {
        review.status == .confirmed && usage == .evaluation && !citations.isEmpty
    }

    public var isPendingAdjudication: Bool { review.status == .adjudicationPending }

    /// The four identity axes a few-shot/prompt record is compared against.
    /// Filename family is included because a renamed copy of one document is the
    /// commonest way an evaluation set leaks into a prompt set.
    public var independenceKeys: Set<String> {
        var keys: Set<String> = ["cluster:" + source.projectClusterKey]
        if let uuid = source.sourceUUID { keys.insert("uuid:" + uuid) }
        if let sha = source.sha256 { keys.insert("sha:" + sha.lowercased()) }
        keys.insert("family:" + Self.filenameFamily(of: source.redactedFilename))
        if let group = source.nearDuplicateGroup { keys.insert("near:" + group) }
        return keys
    }

    /// Lowercased stem with version, copy and duplicate markers removed, so
    /// `报告 v2.docx`, `报告-V3(最终).docx` and `报告 副本.docx` collapse to one
    /// family. Deterministic and auditable by hand: no embedding, no model.
    static func filenameFamily(of filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        var spaced = ""
        for scalar in stem.unicodeScalars {
            spaced.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        // Markers are removed as substrings, not as whole tokens: `副本最终` is
        // one token, and a rule that only dropped exact tokens would keep two
        // names of the same document in different families.
        let markers = ["副本", "最终", "定稿", "修改", "拷贝", "copy", "final", "new", "old", "draft", "backup"]
        var reduced = spaced
        for marker in markers { reduced = reduced.replacingOccurrences(of: marker, with: " ") }
        let tokens = reduced.split(separator: " ").map(String.init).filter { token in
            !token.allSatisfy(\.isNumber)
                && !(token.first == "v" && token.dropFirst().allSatisfy(\.isNumber) && token.count > 1)
        }
        return tokens.joined(separator: "")
    }
}
