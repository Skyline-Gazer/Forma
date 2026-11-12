import Foundation
import Testing

@testable import FormaCore

/// The bundled JSON Schema and the Swift enums must accept the same vocabulary.
///
/// `GoldRecord.check()` refuses what the code cannot name, and the schema refuses
/// what the frozen format cannot carry - but nothing connected the two, so a value
/// added on one side only showed up when a real dataset file failed to load, or a
/// produced record failed validation. Both directions are checked here because both
/// fail silently in opposite places: a schema-only value means a valid file the app
/// cannot read, a code-only value means a record the app builds and then cannot save.
@Suite("Gold schema and Swift enum parity")
struct GoldSchemaParityTests {
    private func document(_ resource: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "json"))
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any] else {
            Issue.record("\(resource) is not a JSON object")
            return [:]
        }
        return object
    }

    /// Follow one level of `$ref` within the same document, the way the two gold
    /// schemas factor out `metadata` and the small enumerations.
    private func resolve(_ node: Any?, in root: [String: Any]) -> [String: Any]? {
        guard var dictionary = node as? [String: Any] else { return nil }
        var hops = 0
        while let reference = dictionary["$ref"] as? String, hops < 3 {
            let components = reference.split(separator: "/").map(String.init)
            var current: Any? = root
            for part in components.dropFirst() {
                current = (current as? [String: Any])?[part]
            }
            guard let next = current as? [String: Any] else { return nil }
            dictionary = next
            hops += 1
        }
        return dictionary
    }

    private func enumValues(_ root: [String: Any], _ path: [String]) throws -> Set<String> {
        var node: [String: Any]? = root
        for key in path {
            node = resolve(node?[key], in: root)
        }
        guard let raw = node?["enum"] as? [String] else {
            Issue.record("no enum at /\(path.joined(separator: "/"))")
            return []
        }
        return Set(raw)
    }

    private func properties(_ root: [String: Any], _ path: [String]) throws -> Set<String> {
        var node: [String: Any]? = root
        for key in path {
            node = resolve(node?[key], in: root)
        }
        guard let declared = node?["properties"] as? [String: Any] else {
            Issue.record("no properties at /\(path.joined(separator: "/"))")
            return []
        }
        return Set(declared.keys)
    }

    /// Every value the schema admits has to decode, and every case the code
    /// declares has to be admitted.
    /// Failures name the vocabulary in the comment, which is what matters when the
    /// assertion sits behind a helper: the file and line point here, not at the field.
    private func assertParity<T: Codable & RawRepresentable & CaseIterable & Equatable>(
        _ type: T.Type, schema: Set<String>, code: Set<String>, label: String
    ) where T.RawValue == String {
        let decoder = JSONDecoder()
        for value in schema.sorted() {
            let decoded = try? decoder.decode(T.self, from: Data("\"\(value)\"".utf8))
            #expect(decoded != nil, "the schema admits \(label)=\(value) but \(type) cannot decode it")
        }
        let schemaOnly = schema.subtracting(code).sorted()
        let codeOnly = code.subtracting(schema).sorted()
        #expect(schema == code, "\(label): schema-only \(schemaOnly), code-only \(codeOnly)")
    }

    @Test("the record schema and the record enums speak the same vocabulary")
    func recordVocabulary() throws {
        let record = try document("gold-record-1.0.schema")
        assertParity(GoldRecord.ReviewStatus.self,
                     schema: try enumValues(record, ["properties", "review", "properties", "status"]),
                     code: Set(GoldRecord.ReviewStatus.allCases.map(\.rawValue)),
                     label: "review.status")
        assertParity(GoldRecord.Redaction.self,
                     schema: try enumValues(record, ["properties", "review", "properties", "redaction"]),
                     code: Set(GoldRecord.Redaction.allCases.map(\.rawValue)),
                     label: "review.redaction")
        assertParity(GoldRecord.Usage.self,
                     schema: try enumValues(record, ["properties", "usage"]),
                     code: Set(GoldRecord.Usage.allCases.map(\.rawValue)),
                     label: "usage")
        assertParity(GoldRecord.Category.self,
                     schema: try enumValues(record, ["properties", "scenario", "properties", "category"]),
                     code: Set(GoldRecord.Category.allCases.map(\.rawValue)),
                     label: "scenario.category")

        // The twelve metadata keys are the same list the mapping layer validates
        // citations against; a thirteenth on either side is a schema/version change
        // that has to be deliberate, not an oversight in one file.
        let fields = try properties(record, ["properties", "expected", "properties", "metadata"])
        let declared = Set(MetadataFieldID.allCases.map(\.rawValue))
        let schemaOnly = fields.subtracting(declared).sorted()
        let codeOnly = declared.subtracting(fields).sorted()
        #expect(fields == declared, "metadata keys: schema-only \(schemaOnly), code-only \(codeOnly)")
    }

    @Test("the split schema and the removal reasons speak the same vocabulary")
    func splitVocabulary() throws {
        let split = try document("gold-split-1.0.schema")
        assertParity(GoldSplit.RemovalReason.self,
                     schema: try enumValues(split, ["properties", "removed_records", "items",
                                                    "properties", "reason"]),
                     code: Set(GoldSplit.RemovalReason.allCases.map(\.rawValue)),
                     label: "removed_records.reason")
    }

    @Test("removal reasons stay disjoint from the selection ledger's codes")
    func ledgerCodesAreNotSchemaValues() throws {
        // `docs/GOLD-DATASET.md` §2.5 fixes eleven codes for the local selection
        // ledger and says out loud they are a different set from the schema's
        // removal reasons. Nothing enforced that sentence; a name shared between the
        // two would make a "not selected" row indistinguishable from a "removed after
        // selection" row, which is the distinction the whole split rests on.
        let ledger: Set<String> = ["unreadable", "ocr_not_supported", "format_out_of_scope",
                                   "permission_denied", "no_verifiable_evidence", "historical_label_only",
                                   "insufficient_authorization", "sha_pending", "coverage_redundant",
                                   "cluster_cross_side", "deferred"]
        let schema = Set(GoldSplit.RemovalReason.allCases.map(\.rawValue))
        let shared = ledger.intersection(schema).sorted()
        #expect(shared.isEmpty, "codes shared between the ledger and the schema: \(shared)")
        #expect(ledger.count == 11)
    }
}
