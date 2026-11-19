import Foundation

/// A deterministic starting draft, produced without a model.
///
/// What it is: every record is filed into the profile's own "unclassified"
/// category, with every other field left unknown, no evidence cited and `low`
/// confidence. That is the most conservative mapping the profile allows, and it
/// is the correct one for a program that has read no document content: the
/// alternative - guessing a category from an extension - is the exact mistake
/// `ManifestValidator` exists to catch.
///
/// What it is not: a model. `isSubstitute` is `true`, so the evaluation layer
/// refuses every quality claim about a run driven by this answerer, and the
/// manifest records `modelProvider = "offline"`. No socket is opened, no key is
/// read, and `ProviderTransport` refuses a request carrying `.offline`.
///
/// Determinism: the output depends only on the batch's entry refs, the profile's
/// unclassified category and its field list. Two runs over the same inputs and
/// the same profile version produce equal proposals. Identity fields (source id,
/// snapshot, path) come from the batch and are never rewritten here.
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
        // Every shipped profile has its own unclassified destination; a profile
        // without one cannot be mapped conservatively, so the batch fails loudly
        // rather than being filed somewhere invented.
        guard let unclassified = profile.categories.first(where: { $0.identifier.hasSuffix("待分类") }) else {
            return MappingAttempt(proposal: nil, error: .incompatible, modelID: Self.modelID)
        }

        let unknown = Set(MetadataFieldID.allCases).subtracting([.documentcategory])
        let entries = batch.entries.map { item in
            ProposalEntry(
                entryRef: item.ref,
                // No candidate is chosen: membership is the user's decision, and
                // guessing one would be inventing a project association.
                projectAssociation: ProposalAssociation(candidateRef: nil, state: .unconfirmed),
                documentCategory: unclassified.identifier,
                documentType: nil,
                metadata: .allUnknown,
                evidence: [],
                unknownFields: unknown,
                conflicts: [],
                confidence: .low,
                reasoning: "offline planner: filed as \(unclassified.identifier) from the record's name and type; "
                    + "no document content was read, so every other field is unknown")
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
