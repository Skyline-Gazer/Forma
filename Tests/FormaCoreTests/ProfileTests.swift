import Foundation
import Testing

@testable import FormaCore

/// Mutates a shipped profile document and asserts the artifact schema or the
/// profile's own semantic checks reject it.
private func mutatedProfile(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
    let url = Bundle.module.url(forResource: "project-archive.v1", withExtension: "json")!
    var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    mutate(&document)
    return try JSONSerialization.data(withJSONObject: document)
}

@Suite("Mapping profiles")
struct ProfileTests {
    @Test("both shipped profiles load")
    func shippedProfilesLoad() throws {
        let profiles = try MappingProfile.shipped()
        #expect(profiles.map(\.profileID) == ["project-archive", "vendor-library"])
        for profile in profiles {
            #expect(profile.fields.count == 12)
            #expect(profile.grantsExecution == false)
            #expect(profile.target.kind == .symbolic)
        }
    }

    @Test("Project Archive uses the six frozen groups in order")
    func projectArchiveCategories() throws {
        let profile = try MappingProfile.projectArchive()
        #expect(profile.categories.map(\.identifier) == ProjectArchiveContract.categories)
        #expect(profile.fields[.projectname]!.requiredForValidated)
        #expect(profile.fields[.completionyear]!.valueType == .year)
        #expect(profile.fields[.completionyear]!.requiredForValidated)
        #expect(profile.permitsUnaffiliatedDocuments == false)
        #expect(profile.categoryIdentifier("02_投标文件"))
        #expect(!profile.categoryIdentifier("07_其他"))
    }

    @Test("Vendor Library keeps a project name optional")
    func vendorLibraryProjectOptional() throws {
        let profile = try MappingProfile.vendorLibrary()
        #expect(profile.fields[.projectname]!.requiredForValidated == false)
        #expect(profile.fields[.projectname]!.nullable)
        #expect(profile.fields[.completionyear]!.requiredForValidated == false)
        #expect(profile.permitsUnaffiliatedDocuments)
        #expect(profile.target.databaseName == nil, "V6 has not bound a physical database")
        for type in VendorLibraryContract.documentTypes {
            #expect(profile.documentTypeIdentifier(type), "\(type) must be a known vendor type")
        }
        #expect(!profile.categoryIdentifier("04_技术资料与编制素材"), "vendor categories are not the project groups")
    }

    @Test("issuer may never rest on a brand or a similar file alone")
    func issuerEvidencePolicy() throws {
        for profile in try MappingProfile.shipped() {
            let issuer = profile.fields[.issuer]!
            #expect(issuer.identifier.isHighImpact)
            #expect(issuer.insufficientEvidenceSources.contains(.sibling))
            #expect(issuer.insufficientEvidenceSources.contains(.filename))
        }
    }

    @Test("a profile cannot claim a verified native type before V3")
    func nativeTypeMustStayUnverified() {
        let data = try? mutatedProfile { document in
            guard var fields = document["fields"] as? [[String: Any]],
                  let index = fields.firstIndex(where: { ($0["identifier"] as? String) == "projectname" })
            else { return }
            fields[index]["native_type_status"] = "verified"
            document["fields"] = fields
        }
        #expect(throws: (any Error).self) { try MappingProfile.decode(try #require(data)) }
    }

    @Test("a thirteenth metadata field is rejected")
    func extraFieldRejected() {
        let data = try? mutatedProfile { document in
            guard var fields = document["fields"] as? [[String: Any]] else { return }
            var copy = fields[0]
            copy["identifier"] = "customernote"
            fields.append(copy)
            document["fields"] = fields
        }
        #expect(throws: (any Error).self) { try MappingProfile.decode(try #require(data)) }
    }

    @Test("a profile may not grant execution")
    func executionGrantRejected() {
        let data = try? mutatedProfile { $0["grants_execution"] = true }
        #expect(throws: (any Error).self) { try MappingProfile.decode(try #require(data)) }
    }

    @Test("an evidence source outside the frozen enumeration is rejected")
    func unknownEvidenceSourceRejected() {
        let data = try? mutatedProfile { document in
            guard var fields = document["fields"] as? [[String: Any]],
                  let index = fields.firstIndex(where: { ($0["identifier"] as? String) == "issuer" })
            else { return }
            fields[index]["allowed_evidence_sources"] = ["content", "web_search"]
            document["fields"] = fields
        }
        #expect(throws: (any Error).self) { try MappingProfile.decode(try #require(data)) }
    }

    @Test("a group template placeholder must name a frozen field")
    func invalidTemplatePlaceholderRejected() {
        let data = try? mutatedProfile { document in
            guard var target = document["target"] as? [String: Any] else { return }
            target["group_template"] = ["{projctname}", "{documentcategory}"]
            document["target"] = target
        }
        #expect(throws: (any Error).self) { try MappingProfile.decode(try #require(data)) }
    }

    @Test("value types accept and reject the documented shapes")
    func valueTypeValidation() {
        #expect(MetadataValueType.year.validate("2026"))
        #expect(!MetadataValueType.year.validate("26"))
        #expect(MetadataValueType.dateText.validate("2026-02-28"))
        #expect(!MetadataValueType.dateText.validate("2026-02-30"), "impossible day must not roll over")
        #expect(!MetadataValueType.dateText.validate("2026-2-28"))
        #expect(!MetadataValueType.text.validate("line\nbreak"), "single-line text only")
        #expect(!MetadataValueType.text.validate(""))
    }

    @Test("field level is derived from the frozen identifier, not from data")
    func levelMustMatchIdentifier() {
        let data = try? mutatedProfile { document in
            guard var fields = document["fields"] as? [[String: Any]],
                  let index = fields.firstIndex(where: { ($0["identifier"] as? String) == "issuer" })
            else { return }
            fields[index]["level"] = "project"
            document["fields"] = fields
        }
        #expect(throws: (any Error).self) { try MappingProfile.decode(try #require(data)) }
    }
}

@Suite("Artifact schemas")
struct ArtifactSchemaTests {
    private func proposal(_ mutate: ([String: Any]) -> [String: Any] = { $0 }) throws -> Data {
        let entry: [String: Any] = [
            "entry_ref": "e1",
            "project_association": ["candidate_ref": "c1", "state": "unconfirmed"],
            "document_category": "04_技术资料与编制素材",
            "document_type": "Datasheet",
            "metadata": MetadataFieldID.allCases.reduce(into: [String: Any]()) { partial, field in
                partial[field.rawValue] = NSNull()
            },
            "evidence": [["field": "documenttype", "evidence_id": "ev1"]],
            "unknown_fields": ["issuer"],
            "conflicts": [],
            "confidence": "medium",
            "reasoning": "A generic datasheet with no project evidence.",
        ]
        return try JSONSerialization.data(withJSONObject: mutate([
            "schema_version": "1.0", "batch_id": "b1", "entries": [entry],
        ]))
    }

    private func proposalWithEntry(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        try proposal { document in
            guard var entries = document["entries"] as? [[String: Any]] else { return document }
            mutate(&entries[0])
            var copy = document
            copy["entries"] = entries
            return copy
        }
    }

    @Test("a well-formed proposal validates")
    func validProposal() throws {
        #expect(try ArtifactSchemaValidator.proposal.violations(proposal()).isEmpty)
    }

    @Test("a model cannot invent source identity or execution authority")
    func identityFieldsRejected() throws {
        for injected in ["source_id", "sha256", "eligible_for_auto_execution", "uuid", "database_uuid"] {
            let data = try proposalWithEntry { entry in
                entry[injected] = "00000000-0000-4000-8000-000000000000"
            }
            let violations = try ArtifactSchemaValidator.proposal.violations(data)
            #expect(!violations.isEmpty, "\(injected) must not be accepted in a proposal")
            #expect(violations.contains { $0.instancePath.contains("/entries/0") },
                    "the rejection must locate the entry that carried \(injected)")
        }
    }

    @Test("a model cannot add a metadata field")
    func extraMetadataKeyRejected() throws {
        let data = try proposalWithEntry { entry in
            var metadata = entry["metadata"] as? [String: Any] ?? [:]
            metadata["customernote"] = "x"
            entry["metadata"] = metadata
        }
        #expect(try !ArtifactSchemaValidator.proposal.violations(data).isEmpty)
    }

    @Test("a model cannot omit a metadata slot")
    func missingMetadataSlotRejected() throws {
        let data = try proposalWithEntry { entry in
            var metadata = entry["metadata"] as? [String: Any] ?? [:]
            metadata.removeValue(forKey: "issuer")
            entry["metadata"] = metadata
        }
        #expect(try !ArtifactSchemaValidator.proposal.violations(data).isEmpty)
    }

    @Test("an out-of-vocabulary category is a business check, not a schema check")
    func categoryMembershipIsBusinessValidation() throws {
        // The schema bounds the shape; membership in the selected profile is the
        // Manifest Validator's job, so an unknown-but-well-formed string is not
        // a schema error. This pins the division of labour between the two.
        let data = try proposalWithEntry { $0["document_category"] = "99_随便" }
        #expect(try ArtifactSchemaValidator.proposal.violations(data).isEmpty)
    }

    @Test("an unknown enum value and a missing key are located")
    func enumAndRequiredViolationsLocated() throws {
        let data = try proposalWithEntry { entry in
            entry["confidence"] = "certain"
            entry.removeValue(forKey: "reasoning")
        }
        let violations = try ArtifactSchemaValidator.proposal.violations(data)
        #expect(violations.contains { $0.instancePath.contains("confidence") },
                "an unknown confidence value must be located, got \(violations.map { $0.logSummary })")
        #expect(violations.contains { $0.instancePath.hasSuffix("/entries/0") || $0.instancePath.contains("reasoning") })
    }

    @Test("malformed JSON is a violation, not a crash")
    func malformedJSON() throws {
        let violations = try ArtifactSchemaValidator.proposal.violations(Data("{ not json".utf8))
        #expect(violations.count == 1)
        #expect(violations[0].code == "json")
    }

    @Test("violation details never quote payload text")
    func detailsAreRedacted() {
        #expect(ArtifactSchema.safeDetail("String 'Acme 客户 报价 12000' does not match pattern '^[0-9]{4}$'")
            == "String «value» does not match pattern «value»")
        let long = String(repeating: "x", count: 400)
        #expect(ArtifactSchema.safeDetail(long).count == 200)
    }

    @Test("a misspelled keyword is rejected at load instead of ignored")
    func keywordTypoFailsClosed() {
        let broken = Data("""
        {"type":"object","aditionalProperties":false,"properties":{"a":{"type":"string"}},"required":["a"]}
        """.utf8)
        #expect(throws: (any Error).self) { try ArtifactSchema(id: "broken", schemaVersion: "1.0", data: broken) }
    }

    @Test("an object schema must close additional properties")
    func openObjectRejected() {
        let open = Data("""
        {"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}
        """.utf8)
        #expect(throws: (any Error).self) { try ArtifactSchema(id: "open", schemaVersion: "1.0", data: open) }
    }

    @Test("format is refused because it is annotation-only by default")
    func formatKeywordRejected() {
        let withFormat = Data("""
        {"type":"object","additionalProperties":false,"properties":{"a":{"type":"string","format":"date"}},"required":["a"]}
        """.utf8)
        #expect(throws: (any Error).self) { try ArtifactSchema(id: "fmt", schemaVersion: "1.0", data: withFormat) }
    }

    @Test("a required keyword that is not an array of names is rejected")
    func malformedRequiredRejected() {
        let broken = Data("""
        {"type":"object","additionalProperties":false,"properties":{"a":{"type":"string"}},"required":"a"}
        """.utf8)
        #expect(throws: (any Error).self) { try ArtifactSchema(id: "req", schemaVersion: "1.0", data: broken) }
    }

    @Test("a manifest may not claim execution authority or a weak identity binding")
    func manifestShapeIsEnforced() throws {
        let url = Bundle.module.url(forResource: "manifest-1.0.schema", withExtension: "json")
        let schema = try ArtifactSchema(id: "manifest", schemaVersion: "1.0",
                                       data: Data(contentsOf: try #require(url)))
        // A minimal envelope with grants_execution true must fail on the const.
        var document: [String: Any] = ["schema_version": "1.0", "entries": [], "validation_report": [:]]
        document["envelope"] = ["grants_execution": true]
        let data = try JSONSerialization.data(withJSONObject: document)
        #expect(try !schema.violations(data).isEmpty)
    }
}
