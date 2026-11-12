import Foundation

/// The one notion of "the same value" that both the validator and the metrics
/// layer use.
///
/// Keeping this single is not tidiness: `precision_auto` counts a candidate as
/// correct when it agrees with the reference answer, and a candidate is *not*
/// contradicted when the validator judged it supported by the quoted text. If
/// those two comparisons were written twice, a value could be simultaneously
/// supported and wrong, and every rate downstream would be unverifiable.
public enum ValueNormalization {
    /// Case, diacritic and width insensitive, outer whitespace removed. This is
    /// deliberately the weak comparison: what a reviewer wrote in the manifest
    /// and what a model echoed differ in width and capitalisation for reasons
    /// that carry no information about the field.
    ///
    /// It is not a semantic comparison. `2026` and `2026年` are different values
    /// here, and a Profile that wants them treated alike has to say so in its
    /// own normalisation rules rather than inheriting a looser equality.
    public static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Equality of two optional values, where "absent on both sides" is equal and
    /// "absent on one side" is not: a withheld field and a wrong field are scored
    /// by different metrics.
    public static func equal(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (a?, b?): !folded(a).isEmpty && folded(a) == folded(b)
        default: false
        }
    }
}
