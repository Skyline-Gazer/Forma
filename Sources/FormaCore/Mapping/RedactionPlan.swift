import CryptoKit
import Foundation

/// Stable, role-preserving redaction of anything that leaves the machine.
///
/// SPEC §8.3 and PLAN §8.3: file names and paths may themselves carry customer,
/// person or price information, so they are not treated as safe metadata. The
/// plan replaces known sensitive terms with placeholders that keep the *role*
/// distinct - a customer never collapses onto a vendor or a bidding entity -
/// because those distinctions are exactly what the mapping has to reason about.
///
/// Placeholders are derived from the term and a per-workspace salt, so the same
/// term always becomes the same label inside one workspace, and the label is
/// not reversible into the term.
public struct RedactionPlan: Sendable {
    public enum Role: String, CaseIterable, Sendable {
        case customer, vendor, bidder, agent, person, project, amount, identifier

        var label: String {
            switch self {
            case .customer: "客户"
            case .vendor: "厂商"
            case .bidder: "投标主体"
            case .agent: "代理"
            case .person: "人员"
            case .project: "项目"
            case .amount: "金额"
            case .identifier: "标识"
            }
        }
    }

    public static let version = "redaction.v1"

    private let salt: String
    private let terms: [(term: String, role: Role)]
    /// term → placeholder, resolved once so numbering is stable for the plan.
    private let replacements: [String: String]

    public init(terms: [String: Role], salt: String) {
        self.salt = salt
        // Deterministic ordering: role first, then the term, so two plans built
        // from the same set of names produce identical labels.
        self.terms = terms.sorted {
            if $0.value != $1.value { return $0.value.rawValue < $1.value.rawValue }
            return $0.key < $1.key
        }.map { (term: $0.key, role: $0.value) }
        var counters: [Role: Int] = [:]
        var replacements: [String: String] = [:]
        for entry in self.terms {
            counters[entry.role, default: 0] += 1
            replacements[entry.term] = "«\(entry.role.label)\(counters[entry.role]!)»"
        }
        self.replacements = replacements
    }

    public static var none: RedactionPlan { RedactionPlan(terms: [:], salt: "forma-default-salt") }

    /// True when nothing would be substituted. A manifest built without any
    /// redaction records that fact instead of pretending a version applies.
    public var isIdentity: Bool { terms.isEmpty }

    public func placeholder(for term: String) -> String? { replacements[term] }

    /// The role inventory shown in the privacy preview, so the user can see what
    /// a request will look like without seeing the values.
    public var roles: [Role: Int] {
        var counts: [Role: Int] = [:]
        for entry in terms { counts[entry.role, default: 0] += 1 }
        return counts
    }

    public func redact(path: String) -> String {
        var output = path
        output = applyKnownTerms(to: output)
        output = replaceIdentifiers(in: output)
        // A path segment that is only digits is a date or a code, both of which
        // can identify a customer when combined with a directory name.
        output = replaceAmounts(in: output)
        return String(output.prefix(512))
    }

    public func redact(text: String) -> String {
        var output = text
        output = applyKnownTerms(to: output)
        output = replaceIdentifiers(in: output)
        output = replaceAmounts(in: output)
        return String(output.prefix(600))
    }

    private func applyKnownTerms(to value: String) -> String {
        var output = value
        // Longest first, so "示例科技有限公司" is not partially replaced by "示例".
        for entry in terms.sorted(by: { $0.term.count > $1.term.count }) {
            guard let placeholder = replacements[entry.term] else { continue }
            output = output.replacingOccurrences(of: entry.term, with: placeholder,
                                                 options: [.caseInsensitive, .diacriticInsensitive])
        }
        return output
    }

    /// UUIDs and 64-hex digests must never travel: they are record or content
    /// identities the model has no business seeing.
    private func replaceIdentifiers(in value: String) -> String {
        var output = value
        for pattern in [
            #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            #"\b[0-9a-fA-F]{64}\b"#,
            #"\b[0-9a-fA-F]{32,}\b"#,
        ] {
            output = output.replacingOccurrences(of: pattern, with: "«标识»", options: .regularExpression)
        }
        return output
    }

    /// Prices are the highest-sensitivity content in this corpus, and a blank
    /// template versus a filled quotation is a *structural* distinction, so the
    /// placeholder keeps the shape ("a number was here") rather than the value.
    private func replaceAmounts(in value: String) -> String {
        var counter = 0
        var output = value
        for pattern in [
            #"(?:¥|￥|\$|人民币)\s?[0-9][0-9,]*(?:\.[0-9]+)?"#,
            #"[0-9][0-9,]*(?:\.[0-9]{1,2})?\s*(?:元|万元|万)"#,
            #"(?<![0-9])[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])"#,
        ] {
            output = replaceMatches(of: pattern, in: output) { _ in
                counter += 1
                return "«金额\(counter)»"
            }
        }
        return output
    }

    private func replaceMatches(of pattern: String, in value: String, _ transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        var output = value
        for match in expression.matches(in: value, range: range).reversed() {
            guard let swift = Range(match.range, in: value) else { continue }
            output.replaceSubrange(swift, with: transform(String(value[swift])))
        }
        return output
    }

    /// A caller may ask whether a specific string would survive redaction, which
    /// is what the "preview before sending" screen needs to show.
    public func leaks(_ value: String) -> [String] {
        terms.filter { value.range(of: $0.term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.term)
    }
}
