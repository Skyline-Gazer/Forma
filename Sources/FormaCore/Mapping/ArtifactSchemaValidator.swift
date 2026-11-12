import DynamicJSON
import Foundation

/// Draft 2020-12 validation for the JSON artifacts Forma writes and reads.
///
/// PLAN §3 forbids treating Codable decoding as schema validation, so every
/// artifact passes through a real JSON Schema before it is decoded, and every
/// schema is itself checked at load time. Two load-time rules exist because a
/// spec-correct validator fails silently in cases Forma cannot tolerate:
///
/// 1. Unknown keywords are ignored by JSON Schema, so a misspelled
///    `additionalProperties` would leave an object open. Forma rejects any
///    keyword outside its allow-list instead.
/// 2. `format` is an annotation unless format assertion is enabled, and only a
///    closed set of names asserts even then. Forma therefore forbids `format`
///    in its own schemas and uses `pattern`, which always asserts. The dialect
///    is still loaded with format assertion on, so a stray `format` can never
///    become a silently disabled rule.
public struct ArtifactSchema: Sendable {
    /// One constraint mismatch, located by JSON Pointer.
    public struct Violation: Sendable, Equatable, Hashable {
        public let instancePath: String
        /// Stable rule name, e.g. `valueNotFoundInEnum` or `json`.
        public let code: String
        /// Rule wording with any quoted payload snippet removed.
        public let detail: String

        /// A short, log-safe description: rule plus location, never a value.
        public var logSummary: String { "\(code) at \(instancePath.isEmpty ? "/" : instancePath)" }
    }

    public let id: String
    public let schemaVersion: String
    private let schema: JSONSchema

    static let jsonTypes: Set<String> = [
        "object", "array", "string", "number", "integer", "boolean", "null",
    ]

    /// Keywords Forma authorizes. Anything else fails the load, which turns a
    /// silently ignored typo into a visible error.
    static let allowedKeywords: Set<String> = [
        "$schema", "$id", "$defs", "$ref", "$anchor", "$dynamicRef", "$dynamicAnchor",
        "$vocabulary", "$comment",
        "title", "description", "default", "examples", "deprecated",
        "type", "enum", "const",
        "properties", "patternProperties", "additionalProperties", "propertyNames",
        "required", "dependentRequired", "dependentSchemas", "minProperties", "maxProperties",
        "items", "prefixItems", "contains", "minContains", "maxContains",
        "minItems", "maxItems", "uniqueItems",
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
        "unevaluatedItems", "unevaluatedProperties",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "pattern",
        "contentEncoding", "contentMediaType", "contentSchema",
    ]

    init(id: String, schemaVersion: String, data: Data) throws {
        let document: JSON
        let schema: JSONSchema
        do {
            document = try JSON(data: data)
            schema = try JSONSchema(data: data)
        } catch {
            throw FormaError.incompatible
        }
        try Self.lint(document, path: "")
        self.id = id
        self.schemaVersion = schemaVersion
        self.schema = schema
    }

    /// Walks a schema document. Only positions that hold a schema are checked
    /// against the keyword allow-list: the children of `properties`,
    /// `patternProperties` and `$defs` are instance names, and treating those
    /// names as keywords would reject every real schema.
    static func lint(_ value: JSON, path: String) throws {
        guard let object = value.objectValue else { return }
        for (key, child) in object {
            guard allowedKeywords.contains(key) else {
                // Covers both a misspelled rule and a `format`, which would
                // otherwise be an annotation nobody asserts.
                throw FormaError.incompatible
            }
            let childPath = "\(path)/\(key)"
            switch key {
            case "required":
                // A non-array `required` would degrade to no requirement at
                // all, so the shape is checked here rather than trusted.
                guard let names = child.arrayValue, !names.isEmpty,
                      names.allSatisfy({ $0.stringValue != nil }) else { throw FormaError.incompatible }
            case "enum":
                guard let cases = child.arrayValue, !cases.isEmpty else { throw FormaError.incompatible }
            case "properties", "patternProperties", "$defs", "dependentSchemas":
                guard let named = child.objectValue else { throw FormaError.incompatible }
                for (name, schema) in named { try lint(schema, path: "\(childPath)/\(name)") }
            case "dependentRequired":
                guard let named = child.objectValue else { throw FormaError.incompatible }
                for (_, names) in named {
                    guard let list = names.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                        throw FormaError.incompatible
                    }
                }
            case "allOf", "anyOf", "oneOf", "prefixItems":
                guard let branches = child.arrayValue, !branches.isEmpty else { throw FormaError.incompatible }
                for (index, schema) in branches.enumerated() { try lint(schema, path: "\(childPath)/\(index)") }
            case "items", "additionalItems", "contains", "not", "if", "then", "else", "propertyNames",
                 "additionalProperties", "unevaluatedItems", "unevaluatedProperties", "contentSchema":
                if let branches = child.arrayValue {
                    for (index, schema) in branches.enumerated() { try lint(schema, path: "\(childPath)/\(index)") }
                } else {
                    try lint(child, path: childPath)
                }
            case "type":
                // A mistyped `type` fails closed in the evaluator, but a
                // misspelled type name would silently accept everything, so the
                // vocabulary is checked here.
                guard let kinds = child.arrayValue else {
                    guard let name = child.stringValue, Self.jsonTypes.contains(name) else {
                        throw FormaError.incompatible
                    }
                    break
                }
                guard !kinds.isEmpty,
                      kinds.allSatisfy({ $0.stringValue.map(Self.jsonTypes.contains) == true }) else {
                    throw FormaError.incompatible
                }
            case "pattern", "contentEncoding", "contentMediaType", "$id", "$schema", "$anchor",
                 "$ref", "$dynamicRef", "$dynamicAnchor", "title", "description", "$comment":
                guard child.stringValue != nil else { throw FormaError.incompatible }
            case "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
                 "minContains", "maxContains", "minimum", "maximum", "multipleOf":
                guard let number = child.intValue, number >= 0 else { throw FormaError.incompatible }
            case "exclusiveMinimum", "exclusiveMaximum":
                guard child.doubleValue != nil else { throw FormaError.incompatible }
            case "uniqueItems", "deprecated", "readOnly", "writeOnly":
                guard child.boolValue != nil else { throw FormaError.incompatible }
            case "const":
                // `const` accepts any JSON value, so only an absent payload (a
                // keyword written as `"const": {}` by mistake) is a defect.
                guard child.objectValue != nil || child.arrayValue != nil || child.stringValue != nil
                    || child.intValue != nil || child.doubleValue != nil || child.boolValue != nil
                    || child.isNull else {
                    throw FormaError.incompatible
                }
            default:
                break
            }
        }
        // Closed objects only: a schema that declares properties must also say
        // what happens to everything else, and for Forma that answer is always
        // "reject".
        if object["properties"] != nil {
            guard object["additionalProperties"]?.boolValue == false else { throw FormaError.incompatible }
        }
    }

    /// Every constraint the payload breaks. Malformed JSON is reported as a
    /// violation at the document root rather than a crash.
    public func violations(_ data: Data) throws -> [Violation] {
        let instance: JSON
        do {
            instance = try JSON(data: data)
        } catch {
            return [Violation(instancePath: "", code: "json", detail: "The payload is not valid JSON.")]
        }
        let result: JSONSchemaValidationResult
        do {
            result = try instance.validate(with: schema, dialect: JSONSchemaDraft2020.Dialect.validateFormat)
        } catch {
            // The schema could not be evaluated at all: report it as an
            // incompatibility so the capability is disabled rather than passed.
            throw FormaError.incompatible
        }
        return result.errors.map { error in
            Violation(
                instancePath: error.value.location.pointer?.description ?? error.value.location.description,
                code: Self.code(for: error.message.reason),
                detail: Self.safeDetail(error.message.reason.reason)
            )
        }
    }

    /// Rule name without its parameters, so a violation code stays stable and
    /// never carries a quoted value.
    static func code(for reason: any FailureReason) -> String {
        let described = String(describing: reason)
        let head = described.prefix { $0 != "(" }
        return String(head.split(separator: ".").last ?? head)
    }

    /// Rule text quotes the offending value, which for a mapping payload can be
    /// a customer or a price. Keep the rule, drop the quotation.
    static func safeDetail(_ message: String) -> String {
        let redacted = message.replacingOccurrences(of: "'[^']*'", with: "«value»", options: .regularExpression)
        return String(redacted.prefix(200))
    }

    /// Throws when the payload breaks any constraint.
    public func validate(_ data: Data) throws {
        guard try violations(data).isEmpty else { throw FormaError.invalidOutput }
    }

    static func load(resource name: String, schemaVersion: String) throws -> ArtifactSchema {
        // `.process` places each schema at the bundle root, so the lookup uses
        // the file name alone.
        guard let url = Bundle.module.url(forResource: "\(name).schema", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw FormaError.unavailable }
        return try ArtifactSchema(id: name, schemaVersion: schemaVersion, data: data)
    }
}

/// The schemas Forma ships. A broken checked-in schema disables the affected
/// capability with a reported error instead of crashing the process.
public enum ArtifactSchemaValidator {
    private static let profileResult = Result { try ArtifactSchema.load(resource: "profile-1.0", schemaVersion: "1.0") }
    private static let proposalResult = Result { try ArtifactSchema.load(resource: "proposal-1.0", schemaVersion: "1.0") }
    private static let manifestResult = Result { try ArtifactSchema.load(resource: "manifest-1.0", schemaVersion: "1.0") }
    private static let casePackResult = Result { try ArtifactSchema.load(resource: "casepack-1.0", schemaVersion: "1.0") }
    private static let goldRecordResult = Result { try ArtifactSchema.load(resource: "gold-record-1.0", schemaVersion: "1.0") }
    private static let goldSplitResult = Result { try ArtifactSchema.load(resource: "gold-split-1.0", schemaVersion: "1.0") }

    public static var profile: ArtifactSchema { get throws { try profileResult.get() } }
    public static var proposal: ArtifactSchema { get throws { try proposalResult.get() } }
    public static var manifest: ArtifactSchema { get throws { try manifestResult.get() } }
    public static var casePack: ArtifactSchema { get throws { try casePackResult.get() } }
    public static var goldRecord: ArtifactSchema { get throws { try goldRecordResult.get() } }
    public static var goldSplit: ArtifactSchema { get throws { try goldSplitResult.get() } }
}
