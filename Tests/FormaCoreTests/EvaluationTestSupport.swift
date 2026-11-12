import Foundation
@testable import FormaCore

/// Builders shared by the evaluation suites.
///
/// A reference answer and a candidate entry have a lot of moving parts - twelve
/// slots, the four-character floor on bounded text, per-field conflicts - and a
/// suite that re-derives them independently will eventually judge different
/// things while both look green.
enum EvaluationFixtures {
    /// The table `EvaluationMetrics.slices(for:)` builds once per run Profile: one row
    /// per case, carrying its cluster and one column per measure in `allCases` order.
    /// Bootstrap tests need the same shape, and hand-rolling it in two places is how
    /// the two drift apart.
    static func rows(_ cases: [CaseJudgement], runProfile: String? = nil) -> [ClusterBootstrap.Row] {
        cases.map { judgement in
            ClusterBootstrap.Row(clusterKey: judgement.clusterKey,
                                 columns: EvaluationMeasure.allCases.map {
                                     $0.population(in: judgement, runProfile: runProfile)
                                 })
        }
    }

    /// The same rows from a hand-built tally table, for cases that want a specific
    /// cluster structure rather than one judgement per project.
    static func rows(_ columns: [[(numerator: Int, denominator: Int)]],
                     keys: [String]) -> [ClusterBootstrap.Row] {
        zip(columns, keys).map { ClusterBootstrap.Row(clusterKey: $0.1, columns: $0.0) }
    }

    /// The opaque candidate reference the prompt would have issued, and which the
    /// manifest association then records. Five characters, because `Bounded.text`
    /// discards anything shorter than four and the association would silently come
    /// back reading "unspecified basis".
    static let candidateRef = "cr-0001"

    /// A judgement over the run's own candidate table, which is how the project
    /// component of PLAN §8.2 gets checked: the entry carries a candidate reference
    /// and the table says which project that reference named.
    static func judgement(_ gold: GoldRecord, entry: ManifestEntry?, wrongProject: Bool = false)
        -> CaseJudgement {
        CaseJudgement(gold: gold, entry: entry, projectKeys: projectKeys(for: gold, wrong: wrongProject))
    }

    /// The run's candidate table, as `ProjectContext` would state it. `wrong`
    /// resolves the same reference to a different project, which is how a fixture
    /// expresses a mis-attributed file: the manifest always carries only the
    /// reference, so the attribution is wrong or right according to the table the
    /// run was built from, not according to any text inside the entry.
    static func projectKeys(for gold: GoldRecord, wrong: Bool = false) -> [String: String] {
        [candidateRef: wrong ? "cl-pa-999" : (gold.expected.projectReference ?? "cl-pa-001")]
    }

    static func values(_ pairs: [MetadataFieldID: String?] = [:]) throws -> MetadataValues {
        try MetadataValues(Dictionary(uniqueKeysWithValues: MetadataFieldID.allCases.map {
            ($0, pairs[$0] ?? nil)
        }))
    }

    static func gold(_ id: String, expected: [MetadataFieldID: String?],
                     allowUnknown: [MetadataFieldID] = [],
                     cluster: String? = nil,
                     category: GoldRecord.Category = .positive,
                     reviewStatus: GoldRecord.ReviewStatus = .confirmed,
                     profiles: [String] = [ProjectArchiveContract.id],
                     project: String? = nil,
                     usage: GoldRecord.Usage = .evaluation) throws -> GoldRecord {
        try GoldRecord(
            recordID: id, datasetRevision: "1.0.0", profiles: profiles,
            scenario: .init(category: category, description: "scenario for " + id),
            source: .init(projectClusterKey: cluster ?? "cluster-" + id, sourceUUID: nil, sha256: nil,
                          redactedRelativePath: "synthetic/\(id).docx", redactedFilename: "\(id).docx",
                          nearDuplicateGroup: nil),
            expected: .init(state: .mapped, projectReference: project ?? "cl-pa-001", targetCategory: "01_招标文件",
                            targetType: "Tender Announcement", metadata: try values(expected),
                            allowedUnknownFields: Set(allowUnknown)),
            citations: [.init(label: "c1", excerpt: "脱敏片段", locator: nil)],
            annotation: .init(annotatorCode: "A1", annotatedOn: "2026-11-12", basis: "both"),
            review: .init(status: reviewStatus, redaction: .reviewed, reviewerCode: "R1",
                          reviewedOn: "2026-11-12"),
            usage: usage)
    }

    /// A candidate entry, built so that the three components PLAN §8.2 requires of a
    /// correct file are intact by default: the group path carries the reference's
    /// category, a `project_candidate` association carries the run's candidate
    /// reference (in production's own wording, since the manifest records a reference
    /// and never a cluster key), and the reference's `profiles` carry the run's
    /// Profile. Break one to test the file-level rates: `wrongPlacement` moves the
    /// file, `projectKeys(for:wrong:)` mis-resolves the association, and a reference
    /// answer naming another Profile fails the third.
    static func candidate(_ set: [MetadataFieldID: String?], status: FieldOutcome.Status = .evidenced,
                          state: DecisionState = .validated, publishable: Bool = true,
                          confidence: DecisionConfidence = .high, citations: [String] = ["c1"],
                          conflicted: [MetadataFieldID] = [], wrongPlacement: Bool = false,
                          gold: GoldRecord) -> ManifestEntry {
        var metadata = MetadataValues.allUnknown
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            let value = set[field] ?? nil
            // `metadata[field] = nil` is the one assignment that does store a
            // null here: MetadataValues subscript sets an explicit slot, unlike
            // the optional-valued dictionary the helper above builds.
            metadata[field] = value
            // Conflicts attach to the named field only. Stamping every filled
            // slot would turn the whole entry into contradicted output and make a
            // coverage test measure the wrong thing while still looking green.
            let conflicts = value != nil && conflicted.contains(field)
                ? ["与第 3 页的记载相互矛盾"] : []
            fields.append(FieldOutcome(field: field, value: value,
                                       status: value == nil ? .unknown : status,
                                       evidenceIDs: value == nil ? [] : citations,
                                       conflicts: conflicts))
        }
        let category = gold.expected.targetCategory ?? "01_招标文件"
        // The reference answer's own project key is not written into the entry: what
        // production records is the opaque candidate reference, and the table the run
        // was built from resolves it.
        return ManifestEntry(
            sourceID: UUID(), snapshotFingerprint: String(repeating: "a", count: 64), snapshotRevision: 2,
            sourceVersion: 1, relativePath: "p/\(gold.recordID).docx", state: state,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: [wrongPlacement ? "09_其他" : category, "2026"], resolved: true),
            metadata: metadata, fields: fields,
            associations: [ManifestAssociation(kind: .projectCandidate, sourceID: UUID(),
                                               basis: "context revision 3 candidate \(candidateRef)")],
            eligibleForAutoExecution: publishable, invalidatedReason: nil, confidence: confidence,
            providerReasoning: nil)
    }
}
