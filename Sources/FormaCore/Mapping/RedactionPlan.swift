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
/// A term label is `«<role><ordinal>»`, and the ordinal is assigned in the
/// order the term's salted digest falls into. Two properties follow, and neither
/// is a matter of luck: no two terms in a role can share a label, because
/// ordinals are not reused; and the numbering cannot be reproduced without the
/// salt, so holding the name list is not enough to read a request back into
/// names. Amounts are labelled by a digest of the value instead, because figures
/// are not enumerable in advance - two placeholders sharing a code really are
/// the same number, which is the fact a mapping needs when one total appears in
/// prose and again in a table - and the collision risk over the number of
/// distinct figures one batch can carry is under one in a hundred thousand.
public struct RedactionPlan: Sendable, Equatable {
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
    /// term → placeholder, resolved once so a plan and its preview never disagree.
    private let replacements: [String: String]

    public init(terms: [String: Role], salt: String) {
        self.salt = salt
        // Longest term first, because that is the only order replacement needs:
        // "示例科技有限公司" has to go before "示例" can eat part of it.
        self.terms = terms.map { (term: $0.key, role: $0.value) }
            .sorted { $0.term.count != $1.term.count ? $0.term.count > $1.term.count : $0.term < $1.term }
        // Numbering walks the terms in salted-digest order, so the ordinal a
        // name receives says nothing about how the caller listed them and
        // cannot be recomputed without the salt.
        let numbering = terms.keys
            .compactMap { term -> (term: String, key: String)? in
                guard let role = terms[term] else { return nil }
                return (term, Self.digest(of: "\(salt)\u{1f}\(role.rawValue)\u{1f}\(term)"))
            }
            .sorted { $0.key < $1.key }
        var counters: [Role: Int] = [:]
        var replacements: [String: String] = [:]
        for entry in numbering {
            guard let role = terms[entry.term] else { continue }
            counters[role, default: 0] += 1
            replacements[entry.term] = "«\(role.label)\(counters[role]!)»"
        }
        self.replacements = replacements
    }

    /// Amount labels are keyed on the value, so one figure carries one code in
    /// a path and in a body, in this call and the next. A per-call counter would
    /// hand two different prices the same label and reset between entry points.
    private static func amountLabel(digits: String, salt: String) -> String {
        "«金额\(digest(of: "\(salt)\u{1f}\u{1f}\u{1f}\(digits)").prefix(12).uppercased())»"
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

    /// Two plans substitute the same text when every resolved placeholder
    /// agrees, and - where anything is substituted at all - when the salt
    /// agrees too, because the salt is inside every placeholder. An empty plan
    /// substitutes nothing, so no field of it is observable in a request and all
    /// empty plans are the same plan. The ordered term list is derived from
    /// these, so it cannot differ while they match: a caller holding a snapshot
    /// compares plans rather than the fields the snapshot came from.
    public static func == (lhs: RedactionPlan, rhs: RedactionPlan) -> Bool {
        lhs.replacements == rhs.replacements
            && (lhs.replacements.isEmpty || lhs.salt == rhs.salt)
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
        for entry in terms {
            guard let placeholder = replacements[entry.term] else { continue }
            output = output.replacingOccurrences(of: entry.term, with: placeholder,
                                                 options: [.caseInsensitive, .diacriticInsensitive])
        }
        return output
    }

    /// Database and content handles - UUIDs, SHA-256 fingerprints, and any other
    /// long hex run - never travel. The order below matters: the exact-64 rule
    /// has to run before the open-ended `{32,}` one, or the open-ended rule
    /// consumes every SHA-256 first. Replacing a long hex business code that is
    /// not a digest is deliberate: it is still a handle into somebody's system.
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
    /// Matching is deliberately narrow: a bare digit run is far more often a
    /// tender reference, a date or a version than a price, and rewriting one of
    /// those removes the very field the mapping was asked to read.
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

    /// Where a pattern's evidence of "money" comes from: inside its own match, or
    /// from the words in front of the number it accepted.
    private enum MoneyCue {
        case inMatch
        case before
    }

    private static let amountPatterns: [(pattern: String, cue: MoneyCue)] = [
        // A currency symbol in front of the number.
        (#"(?<![0-9A-Za-z])(?:¥|￥|\$|人民币)\s*[0-9][0-9,]*(?:\.[0-9]+)?"#, .inMatch),
        // A number with an explicit unit. A bare `万` is not enough: 万象 and 万达
        // are company names, and their digits must survive.
        (#"(?<![0-9A-Za-z.,\-/:«»])[0-9][0-9,]*(?:\.[0-9]{1,2})?\s*(?:万元|亿元|元)(?![0-9A-Za-z])"#, .inMatch),
        // A thousands-grouped number, which is only money if the words say so.
        (#"(?<![0-9A-Za-z.,\-/:«»])[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?(?![0-9A-Za-z.,\-/:«»])"#, .before),
    ]

    // The words that make a bare grouped number a price. A currency mark
    // adjacent to the figure is handled by the first pattern, but a separated
    // one is not: `人民币，1,200,000` reaches here with 人民币 as its only evidence.
    private static let moneyCues = ["价", "金额", "报价", "费用", "预算", "税", "合计", "付款",
                                    "保证金", "中标", "成本", "人民币"]

    private static func looksLikeAmount(_ text: String, before context: Substring) -> Bool {
        // Cents imply a price. Otherwise the words in front have to say it, over
        // a window wide enough to clear a placeholder: a vendor name in the plan
        // has already become `«厂商1»` by the time this runs, and a narrow window
        // would lose the word 报价 behind it and leave a real price in the
        // request.
        if text.contains(".") { return true }
        let window = String(context.suffix(64))
        return moneyCues.contains { window.contains($0) }
    }

    /// Same number, same label - in a path or a body, in this call or the next.
    /// A per-call counter would let two different figures share one label and
    /// make the model read them as one amount, and would reset between the
    /// path and text entry points.
    private func amountLabel(for text: String) -> String {
        Self.amountLabel(digits: String(text.filter { $0.isNumber }), salt: salt)
    }

    /// A caller may ask whether a specific string would survive redaction, which
    /// is what the "preview before sending" screen needs to show.
    public func leaks(_ value: String) -> [String] {
        terms.filter { value.range(of: $0.term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.term)
    }
}
