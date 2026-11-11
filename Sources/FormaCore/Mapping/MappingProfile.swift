import Foundation

/// A versioned Mapping Profile: the target intent, the closed category and
/// document-type vocabularies, and the per-field evidence policy.
///
/// Profiles are data, shipped as bundled JSON and validated on load. Changing a
/// profile therefore changes `profile_version`, which invalidates the manifests
/// that recorded the older version instead of silently reusing their decisions.
public struct MappingProfile: Decodable, Sendable, Equatable {
    public struct TargetBinding: Codable, Sendable, Equatable {
        /// `symbolic` means the destination is a name/template only: nothing in
        /// Forma may create or resolve it. V6 (live database and group binding)
        /// is still unconfirmed, so both shipped profiles stay symbolic.
        public enum Kind: String, Codable, Sendable {
            case symbolic, live
        }

        public let kind: Kind
        /// The intended database name. Null for Vendor Library, whose physical
        /// database is still an open V6 decision.
        public let databaseName: String?
        public let databaseUUID: String?
        /// Ordered path template. Placeholders are `{field}` names from the
        /// frozen twelve; an unresolved placeholder holds the entry, it is never
        /// guessed from a filename.
        public let groupTemplate: [String]
        /// Binding status shown to the user so a symbolic target is never
        /// mistaken for a confirmed destination.
        public let note: String?

        enum CodingKeys: String, CodingKey {
            case kind, databaseName = "database_name", databaseUUID = "database_uuid"
            case groupTemplate = "group_template", note
        }
    }

    public struct Category: Codable, Sendable, Equatable {
        public let identifier: String
        public let meaning: String

        enum CodingKeys: String, CodingKey {
            case identifier, meaning
        }
    }

    public struct DocumentType: Codable, Sendable, Equatable {
        public let identifier: String
        /// Filename and title clues that may suggest this type. These are
        /// hints for the model, never a deterministic classifier.
        public let clues: [String]
    }

    public struct CasePackReference: Codable, Sendable, Equatable {
        public let id: String
        public let version: String
    }

    public let schemaVersion: String
    public let profileID: String
    public let profileVersion: String
    public let displayName: String
    public let target: TargetBinding
    public let categories: [Category]
    public let documentTypes: [DocumentType]
    public let fields: [MetadataFieldID: MetadataFieldPolicy]
    public let casePack: CasePackReference
    /// Whether a missing project association is allowed to stay null (Vendor
    /// Library) or must hold the entry (Project Archive).
    public let permitsUnaffiliatedDocuments: Bool
    /// Prototype always reports false: eligibility is a simulation of policy,
    /// never an authorization to write.
    public let grantsExecution: Bool
    /// The rules the model must see verbatim, taken from SPEC §5.1/§5.2.
    public let counterExamples: [String]

    public var versionKey: String { "\(profileID)@\(profileVersion)" }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", profileID = "profile_id", profileVersion = "profile_version"
        case displayName = "display_name", target, categories, documentTypes = "document_types"
        case fields, casePack = "case_pack", permitsUnaffiliatedDocuments = "permits_unaffiliated_documents"
        case grantsExecution = "grants_execution", counterExamples = "counter_examples"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        profileID = try container.decode(String.self, forKey: .profileID)
        profileVersion = try container.decode(String.self, forKey: .profileVersion)
        displayName = try container.decode(String.self, forKey: .displayName)
        target = try container.decode(TargetBinding.self, forKey: .target)
        categories = try container.decode([Category].self, forKey: .categories)
        documentTypes = try container.decode([DocumentType].self, forKey: .documentTypes)
        let policies = try container.decode([MetadataFieldPolicy].self, forKey: .fields)
        casePack = try container.decode(CasePackReference.self, forKey: .casePack)
        permitsUnaffiliatedDocuments = try container.decode(Bool.self, forKey: .permitsUnaffiliatedDocuments)
        grantsExecution = try container.decode(Bool.self, forKey: .grantsExecution)
        counterExamples = try container.decode([String].self, forKey: .counterExamples)
        fields = try Self.index(policies)
        try Self.check(self)
    }

    private static func index(_ policies: [MetadataFieldPolicy]) throws -> [MetadataFieldID: MetadataFieldPolicy] {
        var result: [MetadataFieldID: MetadataFieldPolicy] = [:]
        for policy in policies {
            guard result.updateValue(policy, forKey: policy.identifier) == nil else {
                throw FormaError.incompatible
            }
        }
        guard result.count == MetadataFieldID.allCases.count else { throw FormaError.incompatible }
        return result
    }

    /// The rules a JSON Schema cannot express. Shape, length and vocabulary
    /// limits live in `profile-1.0.schema.json` and are enforced there before
    /// this runs; restating them here would give one profile two authorities
    /// measured in different units.
    static func check(_ profile: MappingProfile) throws {
        // Identifier uniqueness is not a schema property, and a duplicate would
        // silently overwrite a field policy in the dictionary this builds.
        guard Set(profile.categories.map(\.identifier)).count == profile.categories.count,
              Set(profile.documentTypes.map(\.identifier)).count == profile.documentTypes.count
        else { throw FormaError.incompatible }
        // A live binding is only meaningful once V6 has confirmed the database.
        if profile.target.kind == .live {
            guard let uuid = profile.target.databaseUUID, UUID(uuidString: uuid) != nil else {
                throw FormaError.incompatible
            }
        }
        // The template may only mix fixed segments with whole `{field}`
        // placeholders, so a typo cannot silently target a nonexistent group.
        for segment in profile.target.groupTemplate {
            guard !segment.isEmpty else { throw FormaError.incompatible }
            if segment.contains("{") || segment.contains("}") {
                let name = segment.dropFirst().dropLast()
                guard segment.hasPrefix("{"), segment.hasSuffix("}"), !name.isEmpty,
                      !name.contains("{"), !name.contains("}"),
                      MetadataFieldID(rawValue: String(name)) != nil else {
                    throw FormaError.incompatible
                }
            }
        }
        try profile.checkFieldContract()
    }

    private func checkFieldContract() throws {
        let category = MetadataFieldID.documentcategory
        guard let categoryPolicy = fields[category] else { throw FormaError.incompatible }
        guard categoryPolicy.valueType == .category, categoryPolicy.requiredForValidated else {
            throw FormaError.incompatible
        }
        // Every profile needs its own unclassified destination, so a document
        // without enough evidence can be placed without inventing a category.
        guard categories.contains(where: { $0.identifier.hasSuffix("待分类") }) else {
            throw FormaError.incompatible
        }
        // Cross-profile contract, true for any profile: the completion year is
        // always a four-digit year, and a profile may only let documents stand
        // without a project if it does not also demand a confirmed one.
        guard fields[MetadataFieldID.completionyear]!.valueType == .year,
              fields[MetadataFieldID.projectname]!.requiredForValidated != permitsUnaffiliatedDocuments
        else { throw FormaError.incompatible }
        // Profile-specific expectations are keyed on the profile's own identity
        // rather than on "not the other one", so adding a third profile cannot be
        // rejected by a rule written for Vendor Library.
        if profileID == ProjectArchiveContract.id {
            // SPEC §5.2.1: an unconfirmed project or an unverified completion
            // year blocks archiving, so both are required here.
            guard fields[MetadataFieldID.projectname]!.requiredForValidated,
                  fields[MetadataFieldID.completionyear]!.requiredForValidated,
                  categories.map(\.identifier) == ProjectArchiveContract.categories
            else { throw FormaError.incompatible }
        }
    }

    public func categoryIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return categories.contains { $0.identifier == value }
    }

    public func documentTypeIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return documentTypes.contains { $0.identifier == value }
    }

    public static let artifactSchemaVersion = "1.0"

    // MARK: Shipped profiles

    public static func projectArchive() throws -> MappingProfile { try load(resource: "project-archive.v1") }
    public static func vendorLibrary() throws -> MappingProfile { try load(resource: "vendor-library.v1") }

    public static func load(resource name: String) throws -> MappingProfile {
        // `.process` places each resource at the bundle root, so the lookup
        // uses the file name alone.
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw FormaError.unavailable }
        return try MappingProfile.decode(data)
    }

    public static func decode(_ data: Data) throws -> MappingProfile {
        try ArtifactSchemaValidator.profile.validate(data)
        return try JSONDecoder().decode(MappingProfile.self, from: data)
    }

    /// Both shipped profiles, in the order the interface lists them.
    public static func shipped() throws -> [MappingProfile] { [try projectArchive(), try vendorLibrary()] }
}

/// Constants that come straight from the frozen SPEC, kept in one place so a
/// profile cannot quietly drift away from them.
public enum ProjectArchiveContract {
    public static let id = "project-archive"
    public static let version = "1.0"
    public static let pendingCategory = "99_待分类"
    public static let categories = [
        "01_招标文件", "02_投标文件", "03_厂商支持文件",
        "04_技术资料与编制素材", "05_报价与商务", "99_待分类",
    ]
}

public enum VendorLibraryContract {
    public static let id = "vendor-library"
    public static let version = "1.0"
    /// SPEC §5.3 / PLAN §5.2: these are document types, not an assumption that
    /// the target database uses the Project Archive six-group layout.
    public static let documentTypes = [
        "Datasheet", "Specification Sheet", "Whitepaper", "Solution",
        "Brochure", "Deployment Guide", "Product Manual",
    ]
}
