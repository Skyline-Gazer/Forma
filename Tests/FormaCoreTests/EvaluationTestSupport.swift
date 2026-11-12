import Foundation
@testable import FormaCore

/// Builders shared by the evaluation suites.
///
/// A reference answer and a candidate entry have a lot of moving parts - twelve
/// slots, the four-character floor on bounded text, per-field conflicts - and a
/// suite that re-derives them independently will eventually judge different
/// things while both look green.
enum EvaluationFixtures {
    /// The table `EvaluationMetrics.slices(for:)` builds once per run: one row per
    /// case, one column per measure, in `allCases` order. Bootstrap tests need the
    /// same shape, and hand-rolling it in two places is how the two drift apart.
    static func populations(_ cases: [CaseJudgement]) -> [[(numerator: Int, denominator: Int)]] {
        cases.map { judgement in EvaluationMeasure.allCases.map { $0.population(in: judgement) } }
    }

    /// The cluster keys of the same sample, in the same order.
    static func keys(_ cases: [CaseJudgement]) -> [String] { cases.map(\.clusterKey) }

    static func values(_ pairs: [MetadataFieldID: String?] = [:]) throws -> MetadataValues {
        try MetadataValues(Dictionary(uniqueKeysWithValues: MetadataFieldID.allCases.map {
            ($0, pairs[$0] ?? nil)
        }))
    }

    static func gold(_ id: String, expected: [MetadataFieldID: String?],
                      allowUnknown: [MetadataFieldID] = [],
                      cluster: String? = nil,
                      category: GoldRecord.Category = .positive,
                      profiles: [String] = [ProjectArchiveContract.id]) throws -> GoldRecord {
        try GoldRecord(
            recordID: id, datasetRevision: "1.0.0", profiles: profiles,
            scenario: .init(category: category, description: "scenario for " + id),
            source: .init(projectClusterKey: cluster ?? "cluster-" + id, sourceUUID: nil, sha256: nil,
                          redactedRelativePath: "synthetic/\(id).docx", redactedFilename: "\(id).docx",
                          nearDuplicateGroup: nil),
            expected: .init(state: .mapped, projectReference: "PRJ", targetCategory: "01_招标文件",
                            targetType: "Tender Announcement", metadata: try values(expected),
                            allowedUnknownFields: Set(allowUnknown)),
            citations: [.init(label: "c1", excerpt: "脱敏片段", locator: nil)],
            annotation: .init(annotatorCode: "A1", annotatedOn: "2026-11-12", basis: "both"),
            review: .init(status: .confirmed, redaction: .reviewed, reviewerCode: "R1",
                          reviewedOn: "2026-11-12"),
            usage: .evaluation)
    }

    /// A candidate entry whose every slot carries `status`, with the fields in
    /// `set` filled from the reference answer's own vocabulary.
    static func candidate(_ set: [MetadataFieldID: String?], status: FieldOutcome.Status = .evidenced,
                           state: DecisionState = .validated, publishable: Bool = true,
                           confidence: DecisionConfidence = .high, citations: [String] = ["c1"],
                           conflicted: [MetadataFieldID] = [], gold: GoldRecord) -> ManifestEntry {
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
        return ManifestEntry(
            sourceID: UUID(), snapshotFingerprint: String(repeating: "a", count: 64), snapshotRevision: 2,
            sourceVersion: 1, relativePath: "p/\(gold.recordID).docx", state: state,
            target: ManifestTarget(databaseName: "Project_Archive", groupPath: ["2026"], resolved: true),
            metadata: metadata, fields: fields, associations: [],
            eligibleForAutoExecution: publishable, invalidatedReason: nil, confidence: confidence,
            providerReasoning: nil)
    }
}
