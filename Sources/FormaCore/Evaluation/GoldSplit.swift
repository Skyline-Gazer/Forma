import Foundation

/// The fixed partition a measurement was taken against.
///
/// PLAN §8.1 requires the split to be pinned, so the manifest is the artefact a
/// reviewer re-checks: it names the evaluation records, the prompt-side records,
/// and the reason every candidate was taken out. A number that cannot be traced
/// back to one of these three lists is not reproducible, whatever the model
/// answered.
public struct GoldSplit: Codable, Sendable, Equatable {
    public enum RemovalReason: String, Codable, Sendable, CaseIterable {
        case promptClusterOverlap = "prompt_cluster_overlap"
        case promptSourceOverlap = "prompt_source_overlap"
        case promptHashOverlap = "prompt_hash_overlap"
        case promptFilenameFamilyOverlap = "prompt_filename_family_overlap"
        case nearDuplicate = "near_duplicate"
        case sameFileOtherVersion = "same_file_other_version"
        case adjudicationUnresolved = "adjudication_unresolved"
        case privacyReviewFailed = "privacy_review_failed"
        case duplicateRecordID = "duplicate_record_id"
    }

    public struct Removal: Codable, Sendable, Equatable {
        public let recordID: String
        public let reason: RemovalReason
        public let counterpartyRecordID: String?

        enum CodingKeys: String, CodingKey {
            case recordID = "record_id", reason, counterpartyRecordID = "counterparty_record_id"
        }
    }

    public struct CasePackReference: Codable, Sendable, Equatable {
        public let id: String
        public let version: String
    }

    public let schemaVersion: String
    public let splitID: String
    public let datasetRevision: String
    public let generatedOn: String
    public let casePack: CasePackReference
    public let promptRecordIDs: Set<String>
    public let evaluationRecordIDs: Set<String>
    public let removed: [Removal]
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", splitID = "split_id", datasetRevision = "dataset_revision"
        case generatedOn = "generated_on", casePack = "casepack"
        case promptRecordIDs = "prompt_record_ids", evaluationRecordIDs = "evaluation_record_ids"
        case removed = "removed_records", notes
    }

    public init(schemaVersion: String = "1.0", splitID: String, datasetRevision: String, generatedOn: String,
                casePack: CasePackReference, promptRecordIDs: Set<String>, evaluationRecordIDs: Set<String>,
                removed: [Removal], notes: String?) throws {
        self.schemaVersion = schemaVersion
        self.splitID = splitID
        self.datasetRevision = datasetRevision
        self.generatedOn = generatedOn
        self.casePack = casePack
        self.promptRecordIDs = promptRecordIDs
        self.evaluationRecordIDs = evaluationRecordIDs
        self.removed = removed
        self.notes = notes
        try Self.check(self)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        splitID = try container.decode(String.self, forKey: .splitID)
        datasetRevision = try container.decode(String.self, forKey: .datasetRevision)
        generatedOn = try container.decode(String.self, forKey: .generatedOn)
        casePack = try container.decode(CasePackReference.self, forKey: .casePack)
        promptRecordIDs = try container.decode(Set<String>.self, forKey: .promptRecordIDs)
        evaluationRecordIDs = try container.decode(Set<String>.self, forKey: .evaluationRecordIDs)
        removed = try container.decode([Removal].self, forKey: .removed)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        try Self.check(self)
    }

    static func check(_ split: GoldSplit) throws {
        guard split.schemaVersion == "1.0" else { throw FormaError.incompatible }
        // The three lists partition the dataset: scored, taught, withdrawn. Each
        // pair has to be disjoint, because `GoldDataset.unaccounted` reads their
        // union as "someone decided about this record", and a record listed twice
        // with two meanings would be counted as decided by both.
        let removedIDs = Set(split.removed.map { $0.recordID })
        guard split.promptRecordIDs.isDisjoint(with: split.evaluationRecordIDs),
              split.promptRecordIDs.isDisjoint(with: removedIDs),
              removedIDs.isDisjoint(with: split.evaluationRecordIDs) else {
            throw FormaError.incompatible
        }
        guard split.removed.count == removedIDs.count else { throw FormaError.incompatible }
    }
}
