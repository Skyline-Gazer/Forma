import Foundation

/// The eligibility-filtered input of one mapping run (SPEC v0.1.2 §6.1-1).
///
/// It carries two things that must travel together: the candidate entries the
/// model may see, and the binding that identifies the judgement that produced
/// them. A caller that maps the candidates without the binding would produce a
/// Manifest that cannot be reproduced, invalidated or explained later — the
/// binding is what ties a decision to the revision it belongs to.
///
/// The type exists so that the Context and the Mapping run cannot disagree
/// about which files were eligible: both take this one value.
public struct EligibilitySelection: Sendable {
    /// The INCLUDE subset — the only records that may enter Mapping.
    public let entries: [SourceEntry]
    /// The policy identity and decision fingerprint (see `ContextEligibilityBinding`).
    public let binding: ContextEligibilityBinding

    public init(entries: [SourceEntry], binding: ContextEligibilityBinding) {
        self.entries = entries
        self.binding = binding
    }

    /// The selection a view implies: its mapping candidates and its binding.
    public init(view: EligibilityView) {
        self.init(entries: view.mappingCandidates(), binding: view.contextBinding)
    }
}

extension EligibilityView {
    /// The filtered input a Context and a Mapping run may both use.
    public var selection: EligibilitySelection { EligibilitySelection(view: self) }
}
