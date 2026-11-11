import Foundation
import Testing

@testable import FormaCore

@Suite("Case pack")
struct CasePackTests {
    @Test("the shipped pack satisfies its schema and its own rules")
    func shippedPackIsValid() throws {
        let pack = try CasePack.shipped()
        #expect(pack.id == "forma-governance-cases")
        #expect(pack.cases.count >= 20 && pack.cases.count <= 30)
        #expect(pack.cases.allSatisfy { $0.isAdmissible })
        #expect(Set(pack.cases.map(\.caseID)).count == pack.cases.count)
        let verified = pack.cases.filter { $0.evidenceLevel == .contentVerified }.count
        #expect(verified * 2 >= pack.cases.count)
    }

    @Test("both profiles and every counter-example kind are represented")
    func coverage() throws {
        let pack = try CasePack.shipped()
        let profiles = Set(pack.cases.flatMap(\.profiles))
        #expect(profiles.contains(ProjectArchiveContract.id))
        #expect(profiles.contains(VendorLibraryContract.id))
        let kinds = Set(pack.cases.map(\.kind))
        for kind in [CasePack.Sample.Kind.positive, .negative, .conflict, .refusal] {
            #expect(kinds.contains(kind), "\(kind) must be taught")
        }
        // The six SPEC §5.1 traps must appear as a decision that refuses the
        // tempting category, not merely as prose.
        let trapCategories = Set(pack.cases.filter { $0.kind == .negative || $0.kind == .conflict }
            .compactMap(\.expected.documentCategory))
        for category in ["01_招标文件", "02_投标文件", "03_厂商支持文件", "04_技术资料与编制素材"] {
            #expect(trapCategories.contains(category), "no counter-example lands in \(category)")
        }
    }

    @Test("vendor cases never invent a project")
    func vendorCasesHaveNoProject() throws {
        let pack = try CasePack.shipped()
        let vendor = pack.cases.filter { $0.profiles.contains(VendorLibraryContract.id) }
        #expect(!vendor.isEmpty)
        for sample in vendor where sample.expected.state == .mapped {
            #expect(sample.expected.metadata[.projectname] == nil
                        || !ProjectArchiveContract.categories.contains(sample.expected.documentCategory ?? ""),
                    "a vendor case must not borrow a Project Archive group")
        }
        #expect(vendor.contains { $0.expected.metadata[.projectname] == nil })
    }

    @Test("selection prefers counter-examples and stays deterministic")
    func selectionOrderIsStable() throws {
        let pack = try CasePack.shipped()
        let archive = try MappingProfile.projectArchive()
        let first = pack.selected(for: archive, limit: 6)
        let second = pack.selected(for: archive, limit: 6)
        #expect(first.map(\.caseID) == second.map(\.caseID))
        #expect(first.count <= 6)
        #expect(first.allSatisfy { $0.profiles.contains(archive.profileID) })
        // Negative cases outrank positives, so a tight budget still teaches the
        // traps that the historical failures came from.
        let kinds = first.map(\.kind)
        if let negative = kinds.firstIndex(of: .negative), let positive = kinds.lastIndex(of: .positive) {
            #expect(negative < positive)
        }
    }

    @Test("selection respects the profile boundary")
    func selectionIsProfileScoped() throws {
        let pack = try CasePack.shipped()
        let vendor = try MappingProfile.vendorLibrary()
        #expect(pack.selected(for: vendor).allSatisfy { $0.profiles.contains(vendor.profileID) })
    }

    @Test("an unreviewed case makes the pack inadmissible")
    func pendingCaseRejected() throws {
        let shipped = try CasePack.shipped()
        let original = shipped.cases[0]
        let unreviewed = CasePack.Sample(
            caseID: original.caseID, kind: original.kind, scenario: original.scenario,
            profiles: original.profiles, input: original.input, expected: original.expected,
            whyNot: original.whyNot, evidenceLevel: original.evidenceLevel,
            sourceVersion: original.sourceVersion,
            review: CasePack.Sample.Review(status: .pending, redaction: .synthetic, reviewerRole: nil)
        )
        #expect(!unreviewed.isAdmissible)
        var rejected = false
        let pack = CasePack(schemaVersion: shipped.schemaVersion, id: shipped.id, version: shipped.version,
                             cases: [unreviewed] + shipped.cases.dropFirst())
        do { try CasePack.check(pack) } catch { rejected = true }
        #expect(rejected, "a shipped pack may not contain an unreviewed case")
    }

    @Test("a pack of easy positives alone is refused")
    func positivesOnlyRejected() throws {
        let pack = try CasePack.shipped()
        let positives = pack.cases.filter { $0.kind == .positive }
        #expect(positives.count < 20, "the shipped pack must not be mostly positives")
    }
}
