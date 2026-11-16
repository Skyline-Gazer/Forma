import Foundation

/// The eligibility-filtered input of one mapping run (SPEC v0.1.2 §6.1-1).
///
/// It carries the view the decision came from: the candidate entries the model
/// may see, the binding that identifies the judgement, and the per-record
/// decisions that let a later reader explain what happened. A caller that maps
/// the candidates without the binding would produce a Manifest that cannot be
/// reproduced, invalidated or explained later — the binding is what ties a
/// decision to the revision it belongs to.
///
/// The type exists so that the Context and the Mapping run cannot disagree
/// about which files were eligible: both take this one value.
public struct EligibilitySelection: Sendable {
    /// The view the decision was made on. It carries the records that were
    /// held back as well as the ones that were kept, which is what makes an
    /// exclusion explainable after the fact.
    public let view: EligibilityView

    /// The INCLUDE subset — the only records that may enter Mapping.
    public var entries: [SourceEntry] { view.mappingCandidates() }
    /// The policy identity and decision fingerprint (see `ContextEligibilityBinding`).
    public var binding: ContextEligibilityBinding { view.contextBinding }

    public init(view: EligibilityView) {
        self.view = view
    }
}

extension EligibilityView {
    /// The filtered input a Context and a Mapping run may both use.
    public var selection: EligibilitySelection { EligibilitySelection(view: self) }
}
