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
/// A term label is `«<role><ordinal>»`, and the ordinal is assigned by the
/// order the term's salted digest falls into, not by alphabet or input order.
/// The same term set with the same salt therefore always produces the same
/// labels, the label cannot be reversed into the term without the salt, and
/// the numbering reveals nothing about how the caller happened to list its
/// names. Amounts are labelled by a digest of the value itself, so two
/// placeholders sharing a suffix really are the same number - which is the
/// fact a mapping needs when a total appears in prose and in a table.
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
        self.terms = Self.ordered(terms: terms, salt: salt)
        var counters: [Role: Int] = [:]
        var replacements: [String: String] = [:]
        for entry in self.terms {
            counters[entry.role, default: 0] += 1
            replacements[entry.term] = "«\(entry.role.label)\(counters[entry.role]!)»"
        }
        self.replacements = replacements
    }

    /// Role first (so the inventory stays readable), then the salted digest of
    /// the term. Hash ordering is what makes the ordinal carry no information
    /// back to the caller's input order or to anyone who guesses the list.
    private static func ordered(terms: [String: Role], salt: String) -> [(term: String, role: Role)] {
        terms.map { (term: $0.key, role: $0.value, key: digest(of: "\(salt)\u{1f}\($0.key)")) }
            .sorted {
                if $0.role != $1.role { return $0.role.rawValue < $1.role.rawValue }
                if $0.key != $1.key { return $0.key < $1.key }
                return $0.term < $1.term
            }
            .map { (term: $0.term, role: $0.role) }
    }

    private static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
        // Amounts before identifiers: a placeholder is not neutral text, and
        // replacing a record id first would hand the amount pass a digit run
        // whose neighbour is now `»` - inventing a price next to an id that
        // never had one. A path segment that is only digits is a date or a
        // code, both of which can identify a customer when combined with a
        // directory name.
        output = replaceAmounts(in: output)
        output = replaceIdentifiers(in: output)
        return String(output.prefix(512))
    }

    public func redact(text: String) -> String {
        var output = text
        output = applyKnownTerms(to: output)
        // See `redact(path:)`: the order is part of the guarantee.
        output = replaceAmounts(in: output)
        output = replaceIdentifiers(in: output)
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
    ///
    /// Matching is deliberately narrow. A bare digit run is far more often a
    /// tender reference (`ZB-DEMO-2026-014`), a date (`2026年3月`) or a version
    /// (`v1.234`) than a price, and rewriting one of those into an amount
    /// placeholder silently removes the very field the mapping was asked to
    /// read. A number counts as money only when it carries a currency unit, has
    /// cents, or is thousands-grouped with money words in front of it.
    private func replaceAmounts(in value: String) -> String {
        var output = value
        for pattern in Self.amountPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            for match in expression.matches(in: output, range: range).reversed() {
                guard let swift = Range(match.range, in: output) else { continue }
                let text = String(output[swift])
                // Never rewrite something an earlier pass already replaced.
                if text.contains("«") { continue }
                guard Self.looksLikeAmount(text, before: output[output.startIndex..<swift.lowerBound]) else {
                    continue
                }
                output.replaceSubrange(swift, with: amountLabel(for: text))
            }
        }
        return output
    }

    private static let amountPatterns = [
        // A currency symbol in front of the number.
        #"(?<![0-9A-Za-z])(?:¥|￥|\$|人民币)\s*[0-9][0-9,]*(?:\.[0-9]+)?"#,
        // A number with an explicit unit. A bare `万` is not enough: 万象 and
        // 万达 are company names, and their digits must survive.
        #"(?<![0-9A-Za-z.,\-/:«»])[0-9][0-9,]*(?:\.[0-9]{1,2})?\s*(?:万元|亿元|元)(?![0-9A-Za-z])"#,
        // Comma-grouped numbers, judged by the words in front of them. A
        // placeholder on either side means this number belongs to something the
        // plan already rewrote, so it is not evidence of a price.
        #"(?<![0-9A-Za-z.,\-/:«»])[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?(?![0-9A-Za-z.,\-/:«»])"#,
    ]

    private static let moneyCues = ["价", "金额", "报价", "费用", "预算", "税", "合计", "付款",
                                    "保证金", "中标", "成本", "人民币"]

    private static func looksLikeAmount(_ text: String, before context: Substring) -> Bool {
        if text.contains(where: { $0 == "¥" || $0 == "￥" || $0 == "$" }) { return true }
        if text.contains("元") || text.contains("人民币") { return true }
        if text.contains(".") { return true }
        let window = String(context.suffix(16))
        return moneyCues.contains { window.contains($0) }
    }

    /// Same number, same label - in a path or a body, in this call or the next.
    /// A per-call counter would let two different figures share one label and
    /// make the model read them as one amount, and would reset between the
    /// path and text entry points.
    private func amountLabel(for text: String) -> String {
        let digits = String(text.filter { $0.isNumber })
        var hasher = SHA256()
        hasher.update(data: Data("\(salt)\u{1f}\u{1f}\u{1f}\(digits)".utf8))
        return "«金额\(hasher.finalize().prefix(2).map { String(format: "%02X", $0) }.joined())»"
    }

    /// A caller may ask whether a specific string would survive redaction, which
    /// is what the "preview before sending" screen needs to show.
    public func leaks(_ value: String) -> [String] {
        terms.filter { value.range(of: $0.term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.term)
    }
}
