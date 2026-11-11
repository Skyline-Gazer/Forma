import Foundation
import Testing

@testable import FormaCore

/// The twelve-slot metadata map is the boundary between a model's answer and
/// storage: an explicit null must stay distinguishable from an absent key, and
/// no extra identifier may survive decoding. These are the rules the Manifest
/// Validator and the interface both depend on.
@Suite("Metadata values")
struct MetadataValuesTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("all twelve nulls decode to unknown slots")
    func allNull() throws {
        let values = try JSONDecoder().decode(MetadataValues.self, from: json("""
        {"projectname":null,"completionyear":null,"bidderentity":null,"department":null,
         "salesowner":null,"endcustomer":null,"biddeadline":null,"tenderreference":null,
         "bsdcode":null,"documentcategory":null,"documenttype":null,"issuer":null}
        """))
        #expect(values.nonNullFields.isEmpty)
        #expect(values[.projectname] == nil)
    }

    @Test("a missing slot is rejected rather than treated as null")
    func missingSlotRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MetadataValues.self, from: self.json("""
            {"projectname":"示例项目","completionyear":"2026","bidderentity":null,"department":null,
             "salesowner":null,"endcustomer":null,"biddeadline":null,"tenderreference":null,
             "bsdcode":null,"documentcategory":"02_投标文件","documenttype":null}
            """))
        }
    }

    @Test("a thirteenth slot is rejected")
    func extraSlotRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MetadataValues.self, from: self.json("""
            {"projectname":null,"completionyear":null,"bidderentity":null,"department":null,
             "salesowner":null,"endcustomer":null,"biddeadline":null,"tenderreference":null,
             "bsdcode":null,"documentcategory":null,"documenttype":null,"issuer":null,"note":"x"}
            """))
        }
    }

    @Test("encoding always writes all twelve keys")
    func encodingIsComplete() throws {
        var values = MetadataValues.allUnknown
        values[.projectname] = "示例项目"
        let data = try JSONEncoder().encode(values)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(MetadataFieldID.allCases.map(\.rawValue)))
        #expect(object["issuer"] is NSNull)
        #expect(object["projectname"] as? String == "示例项目")
    }

    @Test("constructing a partial map is refused")
    func partialConstruction() {
        #expect(throws: (any Error).self) {
            try MetadataValues([.projectname: "示例项目"])
        }
    }

    @Test("a proposal entry survives the encoder, the schema and the decoder")
    func proposalRoundTrip() throws {
        let entry = ProposalEntry(
            entryRef: "e1",
            projectAssociation: ProposalAssociation(candidateRef: "c1", state: .unconfirmed),
            documentCategory: "04_技术资料与编制素材",
            documentType: "Datasheet",
            metadata: .allUnknown,
            evidence: [EvidenceCitation(field: .documenttype, evidenceID: "ev1")],
            unknownFields: [.issuer],
            conflicts: [],
            confidence: .medium,
            reasoning: "A generic datasheet with no project evidence."
        )
        let proposal = MappingProposal(batchID: "b1", entries: [entry])
        let data = try FormaJSON.encode(proposal)
        #expect(try ArtifactSchemaValidator.proposal.violations(data).isEmpty,
                "an internally built proposal must satisfy the same schema as a provider's answer")
        #expect(try FormaJSON.decode(MappingProposal.self, from: data) == proposal)
    }

    @Test("an encoded manifest satisfies the manifest schema")
    func manifestRoundTrip() throws {
        let profile = try MappingProfile.projectArchive()
        let entry = ManifestEntry(
            sourceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            snapshotFingerprint: String(repeating: "a", count: 64),
            snapshotRevision: 1, sourceVersion: 1, relativePath: "示例项目/02_投标/文件.pdf",
            state: .hold,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["2026", "示例项目", "02_投标文件"], resolved: true)
        )
        let envelope = ManifestEnvelope(
            manifestID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, revision: 1,
            supersedesRevision: nil, scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            sourceRootID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, profile: profile,
            casePack: (profile.casePack.id, profile.casePack.version), modelProvider: "anthropic",
            modelID: "claude-haiku-4-5-20251001", contextRevision: 1, promptVersion: "mapping.v1",
            extractorVersion: "evidence.v1", redactionVersion: nil,
            inputDigest: String(repeating: "b", count: 64), contextDigest: String(repeating: "c", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft
        )
        let manifest = Manifest(envelope: envelope, entries: [entry])
        let data = try FormaJSON.encode(manifest, pretty: true)
        #expect(try ArtifactSchemaValidator.manifest.violations(data).isEmpty,
                "a program-built manifest must satisfy the exported artifact schema")
        #expect(try FormaJSON.decode(Manifest.self, from: data) == manifest)
    }

    @Test("a proposal that invents identity is stopped by the schema")
    func injectedIdentityRejected() throws {
        let text = """
        {"schema_version":"1.0","batch_id":"b1","entries":[{
          "entry_ref":"e1","source_id":"00000000-0000-4000-8000-000000000001",
          "project_association":null,"document_category":null,"document_type":null,
          "metadata":{"projectname":null,"completionyear":null,"bidderentity":null,"department":null,
            "salesowner":null,"endcustomer":null,"biddeadline":null,"tenderreference":null,
            "bsdcode":null,"documentcategory":null,"documenttype":null,"issuer":null},
          "evidence":[],"unknown_fields":[],"conflicts":[],"confidence":"high",
          "reasoning":"Attempt to smuggle a source identifier."}]}
        """
        let data = Data(text.utf8)
        let violations = try ArtifactSchemaValidator.proposal.violations(data)
        #expect(!violations.isEmpty, "the schema must reject an invented source_id")
        // Decoding alone ignores unknown keys, which is exactly why schema
        // validation runs first: the type has no field an identity could land in.
        let decoded = try JSONDecoder().decode(MappingProposal.self, from: data)
        #expect(decoded.entries.first?.entryRef == "e1")
        #expect(Mirror(reflecting: decoded.entries[0]).children.allSatisfy { $0.label != "sourceID" })
    }
}
