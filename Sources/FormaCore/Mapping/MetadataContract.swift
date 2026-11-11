import Foundation

/// The twelve DEVONthink Custom Metadata identifiers frozen by SPEC §5.2.
///
/// This enum is the only way a mapping value can be named: the mapping layer
/// cannot add, rename or migrate a field, and a proposal that mentions any
/// other identifier is rejected before it reaches storage. `documentcategory`
/// and `documenttype` are real Custom Metadata identifiers, not Forma concepts.
public enum MetadataFieldID: String, CaseIterable, Codable, Sendable, Comparable {
    case projectname
    case completionyear
    case bidderentity
    case department
    case salesowner
    case endcustomer
    case biddeadline
    case tenderreference
    case bsdcode
    case documentcategory
    case documenttype
    case issuer

    /// Project-level fields describe the business engagement; document-level
    /// fields describe the file itself. Inheritance rules differ per PLAN §5.3.
    public var level: MetadataFieldLevel {
        switch self {
        case .projectname, .completionyear, .bidderentity, .department, .salesowner,
             .endcustomer, .biddeadline, .tenderreference, .bsdcode:
            .project
        case .documentcategory, .documenttype, .issuer:
            .document
        }
    }

    /// Fields whose wrong value is a business or legal error rather than a
    /// missing detail. PLAN §5.3 keeps these under a stricter evidence policy,
    /// and `issuer` may never be filled from a brand clue alone.
    public var isHighImpact: Bool {
        switch self {
        case .projectname, .completionyear, .bidderentity, .endcustomer, .issuer: true
        default: false
        }
    }

    public static func < (lhs: MetadataFieldID, rhs: MetadataFieldID) -> Bool {
        lhs.allIndex < rhs.allIndex
    }

    private var allIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum MetadataFieldLevel: String, Codable, Sendable {
    case project, document
}

/// The value shape Forma enforces in its own layer. This is deliberately not a
/// claim about the live DEVONthink field type: V3 (on-site Label, native type,
/// null representation) is still blocked, so `nativeTypeStatus` stays
/// `unverified` until a read-only probe against a confirmed database succeeds.
public enum MetadataValueType: String, Codable, Sendable {
    case text
    case year
    case dateText = "date_text"
    case category
    case documentType = "document_type"

    func validate(_ value: String) -> Bool {
        switch self {
        case .text, .category, .documentType:
            !value.isEmpty && value.utf8.count <= 512 && !value.contains("\n")
        case .year:
            value.count == 4 && value.allSatisfy(\.isNumber)
        case .dateText:
            Self.isISO8601Date(value)
        }
    }

    private static func isISO8601Date(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month), day >= 1
        else { return false }
        var components = DateComponents()
        components.year = Int(parts[0]); components.month = month; components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Round-trips the components so an impossible day such as 2026-02-30 is
        // rejected instead of silently rolling over into March.
        guard let date = calendar.date(from: components) else { return false }
        return calendar.component(.year, from: date) == components.year
            && calendar.component(.month, from: date) == components.month
            && calendar.component(.day, from: date) == components.day
    }
}

/// SPEC §6.3 fixes this enumeration. Anything else, including a model-invented
/// "web_search" or "history_label", fails validation.
public enum EvidenceSource: String, Codable, CaseIterable, Sendable {
    case filename, path, content, sibling, fsMetadata = "fs_metadata", mcp
}

/// One field's mapping-layer policy, loaded from a Profile.
public struct MetadataFieldPolicy: Codable, Sendable, Equatable {
    public let identifier: MetadataFieldID
    public let level: MetadataFieldLevel
    public let valueType: MetadataValueType
    /// Required before a document may reach `validated` for archiving. Optional
    /// fields stay null when evidence is missing; a missing optional field never
    /// blocks a mapping on its own.
    public let requiredForValidated: Bool
    public let nullable: Bool
    /// Evidence kinds that may support this field at all.
    public let allowedEvidenceSources: [EvidenceSource]
    /// Evidence kinds that alone are never sufficient for this field.
    public let insufficientEvidenceSources: [EvidenceSource]
    /// Prose from SPEC/PLAN that the model must see with the field rules.
    public let rule: String
    public let nativeTypeStatus: NativeTypeStatus

    enum CodingKeys: String, CodingKey {
        case identifier, level, requiredForValidated = "required_for_validated"
        case nullable, allowedEvidenceSources = "allowed_evidence_sources"
        case insufficientEvidenceSources = "insufficient_evidence_sources"
        case rule, valueType = "value_type", nativeTypeStatus = "native_type_status"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(MetadataFieldID.self, forKey: .identifier)
        level = try container.decode(MetadataFieldLevel.self, forKey: .level)
        valueType = try container.decode(MetadataValueType.self, forKey: .valueType)
        requiredForValidated = try container.decode(Bool.self, forKey: .requiredForValidated)
        nullable = try container.decode(Bool.self, forKey: .nullable)
        allowedEvidenceSources = try container.decode([EvidenceSource].self, forKey: .allowedEvidenceSources)
        insufficientEvidenceSources = try container.decode([EvidenceSource].self, forKey: .insufficientEvidenceSources)
        rule = try container.decode(String.self, forKey: .rule)
        nativeTypeStatus = try container.decode(NativeTypeStatus.self, forKey: .nativeTypeStatus)
        try Self.check(self)
    }

    static func check(_ policy: MetadataFieldPolicy) throws {
        guard policy.level == policy.identifier.level else {
            throw FormaError.incompatible
        }
        // `allowed` lists sources that may support the field at all, while
        // `insufficient` lists sources that may never support it *alone*. The
        // two sets may overlap or be disjoint: a source that is not allowed at
        // all is still worth naming as insufficient, because the model reads
        // both lists as rules. What must not happen is an empty rule set for a
        // required field, which would let anything pass.
        guard !policy.allowedEvidenceSources.isEmpty else { throw FormaError.incompatible }
        // A field that may never be null is required by definition; the reverse
        // is allowed, because "required + nullable" means an unknown value holds
        // the entry rather than licensing the model to invent one.
        guard policy.nullable || policy.requiredForValidated else { throw FormaError.incompatible }
        // SPEC §5.2.1: a brand or a similar historical file is never enough for
        // `issuer`, so the Profile must state that explicitly instead of leaving
        // the restriction to a prompt sentence.
        if policy.identifier == .issuer {
            guard policy.insufficientEvidenceSources.contains(.sibling),
                  policy.insufficientEvidenceSources.contains(.filename) else { throw FormaError.incompatible }
        }
    }
}

public enum NativeTypeStatus: String, Codable, Sendable, Equatable {
    /// V3 has not been probed on a confirmed database for this field.
    case unverified
    /// A read-only probe returned this field's live type and it matched.
    case verified
}
