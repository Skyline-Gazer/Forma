import Foundation

/// A deterministic starting draft, produced without a model.
///
/// What it is: a draft that claims nothing. Every field of every record is
/// unknown, no evidence is cited, and confidence is `low`. That is the most
/// conservative answer the validator accepts, and it is the honest one for a
/// program that has read no document content: `ManifestValidator` rejects any
/// value that cites no evidence, and guessing a category from an extension is the
/// exact mistake it exists to catch.
///
/// What it is not: a model. `isSubstitute` is `true`, so the evaluation layer
/// refuses every quality claim about a run driven by this answerer, and the
/// manifest records `modelProvider = "offline"`. No socket is opened, no key is
/// read, and `ProviderTransport` refuses a request carrying `.offline`.
///
/// Determinism: the output depends only on the batch's entry refs and the
/// metadata field list. Two runs over the same inputs and the same profile version
/// produce equal proposals. Identity fields (source id, snapshot, path) come from
/// the batch and are never rewritten here.
public struct OfflinePlannerAnswerer: MappingAnswering {
    public static let modelID = "offline-planner.v1"

    public init() {}

    public var isSubstitute: Bool { true }

    public func answer(provider: ProbeProvider, model: String, allowCloud: Bool, profile: MappingProfile,
                       context: ProjectContext, casePack: CasePack, batch: MappingBatch,
                       redaction: RedactionPlan) async -> MappingAttempt {
        // A mislabelled run would put a model's name on a draft this code wrote.
        // Refusing is the only behaviour that keeps the manifest truthful.
        guard provider == .offline, model == Self.modelID else {
            return MappingAttempt(proposal: nil, error: .unauthorized, modelID: Self.modelID)
        }
        guard !Task.isCancelled else {
            return MappingAttempt(proposal: nil, error: .cancelled, modelID: Self.modelID)
        }
        // Every field is unknown, including the category.
        //
        // `ManifestValidator` rejects any non-null value that cites no evidence
        // (`evidence_missing`), and this answerer has read no document body, so
        // it cannot cite anything. Filing records into the profile's
        // "unclassified" category would look helpful and be a violation on every
        // row; the truthful draft claims nothing and lets a person decide with
        // the body evidence the app registers for them.
        let entries = batch.entries.map { item in
            ProposalEntry(
                entryRef: item.ref,
                // No candidate is chosen: membership is the user's decision, and
                // guessing one would be inventing a project association.
                projectAssociation: ProposalAssociation(candidateRef: nil, state: .unconfirmed),
                documentCategory: nil,
                documentType: nil,
                metadata: .allUnknown,
                evidence: [],
                unknownFields: Set(MetadataFieldID.allCases),
                conflicts: [],
                confidence: .low,
                reasoning: "offline planner: no document content was read, so no field is claimed; "
                    + "review this record against its own evidence")
        }

        return MappingAttempt(proposal: MappingProposal(batchID: batch.id, entries: entries),
                              modelID: Self.modelID,
                              // No tokens were consumed anywhere: reporting a
                              // number here would be an invented observation.
                              usage: MappingUsage(),
                              latencyMilliseconds: 0,
                              requests: 0)
    }
}
