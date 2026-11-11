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
/// A term label is `«<role><code>»`, where the code is the first twelve hex
/// digits of the term's salted digest. The same term under the same salt always
/// becomes the same label, a label carries nothing back into the term without
/// the salt, and neither the caller's input order nor how many names share a
/// role is revealed. Twelve hex digits is 48 bits: a workspace with ten thousand
/// names in one role still meets its first collision with probability under one
/// in a hundred thousand, and a test over five thousand names pins that the
/// labels a plan hands out are distinct. Amounts use the same construction on
/// the value, so two placeholders sharing a code really are the same number -
/// the fact a mapping needs when one total appears in prose and again in a
/// table.
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
        self.terms = Self.ordered(terms: terms)
        var replacements: [String: String] = [:]
        for entry in self.terms {
            replacements[entry.term] = Self.label(role: entry.role, seed: entry.term, salt: salt)
        }
        self.replacements = replacements
    }

    /// Role first, then the term, so two plans built from the same names always
    /// produce the same labels. The label itself is a salted digest, not a
    /// position in this list.
    private static func ordered(terms: [String: Role]) -> [(term: String, role: Role)] {
        terms.sorted {
            if $0.value != $1.value { return $0.value.rawValue < $1.value.rawValue }
            return $0.key < $1.key
        }.map { (term: $0.key, role: $0.value) }
    }

    private static func label(role: Role, seed: String, salt: String) -> String {
        "«\(role.label)\(digest(of: "\(salt)\u{1f}\(role.rawValue)\u{1f}\(seed)").prefix(12).uppercased())»"
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

    /// Record and content identities must never travel. Three shapes cover them:
    /// a UUID is a database handle; a run of exactly 64 hex digits is a SHA-256
    /// snapshot fingerprint; and any other run of 32 or more hex digits is a
    /// digest of some kind - SHA-1, a content hash, or an internal identifier
    /// this program did not mint but should not forward either. The third rule is
    /// deliberately blunt: a long hex business code is replaced too. That is the
    /// safe direction, because such a code is a handle into somebody else's
    /// system, and the model has no use for any of them.
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
        for entry in Self.amountPatterns {
            guard let expression = try? NSRegularExpression(pattern: entry.pattern) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            for match in expression.matches(in: output, range: range).reversed() {
                guard let swift = Range(match.range, in: output) else { continue }
                let text = String(output[swift])
                // Never rewrite something an earlier pass already replaced.
                if text.contains("«") { continue }
                if entry.cue == .before,
                   !Self.looksLikeAmount(text, before: output[output.startIndex..<swift.lowerBound]) {
                    continue
                }
                output.replaceSubrange(swift, with: amountLabel(for: text))
            }
        }
        return output
    }

    /// How a pattern knows it found a price. `inMatch` means the currency cue is
    /// part of what the expression accepted, so nothing else is consulted;
    /// `before` means the number carries no cue itself and the words in front of
    /// it have to say it is money. Naming that in the type keeps the two
    /// judgments from drifting apart when a pattern is edited.
    private enum MoneyCue {
        case inMatch
        case before
    }

    private static let amountPatterns: [(pattern: String, cue: MoneyCue)] = [
        // A currency symbol in front of the number.
        (#"(?<![0-9A-Za-z])(?:¥|￥|\$|人民币)\s*[0-9][0-9,]*(?:\.[0-9]+)?"#, .inMatch),
        // A number with an explicit unit. A bare `万` is not enough: 万象 and
        // 万达 are company names, and their digits must survive.
        (#"(?<![0-9A-Za-z.,\-/:«»])[0-9][0-9,]*(?:\.[0-9]{1,2})?\s*(?:万元|亿元|元)(?![0-9A-Za-z])"#, .inMatch),
        // Comma-grouped numbers, judged by the words in front of them. A
        // placeholder on either side means this number belongs to something the
        // plan already rewrote, so it is not evidence of a price.
        (#"(?<![0-9A-Za-z.,\-/:«»])[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?(?![0-9A-Za-z.,\-/:«»])"#, .before),
    ]

    // No currency symbol or unit here: those live inside the first two
    // patterns' matches, so a number they explain never reaches this list. What
    // is left is the words that turn a bare grouped number into a price.
    private static let moneyCues = ["价", "金额", "报价", "费用", "预算", "税", "合计", "付款",
                                    "保证金", "中标", "成本"]

    private static func looksLikeAmount(_ text: String, before context: Substring) -> Bool {
        // Cents imply a price; a grouped number without them needs support from
        // the words immediately in front of it.
        if text.contains(".") { return true }
        let window = String(context.suffix(16))
        return moneyCues.contains { window.contains($0) }
    }

    /// Same number, same label - in a path or a body, in this call or the next.
    /// A per-call counter would let two different figures share one label and
    /// make the model read them as one amount, and would reset between the
    /// path and text entry points.
    private func amountLabel(for text: String) -> String {
        Self.label(role: .amount, seed: String(text.filter { $0.isNumber }), salt: salt)
    }

    /// A caller may ask whether a specific string would survive redaction, which
    /// is what the "preview before sending" screen needs to show.
    public func leaks(_ value: String) -> [String] {
        terms.filter { value.range(of: $0.term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.term)
    }
}
