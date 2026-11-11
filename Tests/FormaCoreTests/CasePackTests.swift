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

    /// The shipped pair - pack and profiles - has to agree, and the agreement is
    /// computed by production code (`CasePack.untaughtCategories`), not by string
    /// matching written here. `positivesOnlyRejected`, `conflictKindIsRequired`
    /// and `singleProfilePackRejected` cover the guards in `check` by
    /// construction; `declaredTrapGapsAreReported` covers this one.
    @Test("the shipped pack teaches the traps the shipped profiles declare")
    func coverage() throws {
        let pack = try CasePack.shipped()
        let profiles = [try MappingProfile.projectArchive(), try MappingProfile.vendorLibrary()]
        let kinds = Set(pack.cases.map(\.kind))
        for kind in [CasePack.Sample.Kind.positive, .negative, .conflict, .refusal] {
            #expect(kinds.contains(kind), "\(kind) must be taught")
        }
        #expect(CasePack.untaughtCategories(in: pack, profiles: profiles).isEmpty,
                "a profile names a trap the pack never refuses")
        try CasePack.check(pack, teaching: profiles)
    }

    @Test("a pack that stops refusing a declared trap is reported, not assumed")
    func declaredTrapGapsAreReported() throws {
        let pack = try CasePack.shipped()
        let archive = try MappingProfile.projectArchive()
        // Every counter-example that refuses 03_厂商支持文件 loses that reason, so
        // the profile still declares the trap and the pack no longer teaches it.
        let category = "03_厂商支持文件"
        var stripped: [CasePack.Sample] = []
        for sample in pack.cases {
            if sample.kind == .positive || !sample.whyNot.contains(where: { $0.contains(category) }) {
                stripped.append(sample)
            } else {
                stripped.append(CasePack.Sample(
                    caseID: sample.caseID, kind: sample.kind, scenario: sample.scenario,
                    profiles: sample.profiles, input: sample.input, expected: sample.expected,
                    whyNot: sample.whyNot.map { $0.replacingOccurrences(of: category, with: "该分类") },
                    evidenceLevel: sample.evidenceLevel, sourceVersion: sample.sourceVersion,
                    review: sample.review))
            }
        }
        let gap = CasePack(schemaVersion: pack.schemaVersion, id: pack.id, version: pack.version, cases: stripped)
        let missing = CasePack.untaughtCategories(in: gap, profiles: [archive])
        #expect(missing[archive.profileID] == [category],
                "the production check must name the trap that stopped being taught, got \(missing)")
        #expect(throws: FormaError.incompatible) {
            try CasePack.check(gap, teaching: [archive])
        }
    }

    @Test("a pack that teaches only one profile is refused")
    func singleProfilePackRejected() throws {
        let shipped = try CasePack.shipped()
        let archive = shipped.cases.filter { $0.profiles.contains(ProjectArchiveContract.id) }
        // Twenty samples drawn from the Project Archive cases: size, admissibility,
        // counter-example kinds and the evidence ratio all clear, so the only
        // rule left to fail is the one under test.
        var cases: [CasePack.Sample] = []
        for index in 0..<20 {
            let base = archive[index % archive.count]
            cases.append(CasePack.Sample(caseID: "solo-\(index)", kind: base.kind, scenario: base.scenario,
                                         profiles: [ProjectArchiveContract.id], input: base.input,
                                         expected: base.expected, whyNot: base.whyNot,
                                         evidenceLevel: base.evidenceLevel, sourceVersion: base.sourceVersion,
                                         review: base.review))
        }
        let pack = CasePack(schemaVersion: shipped.schemaVersion, id: shipped.id, version: shipped.version,
                             cases: cases)
        var rejected = false
        do { try CasePack.check(pack) } catch { rejected = true }
        #expect(rejected, "a pack that teaches one profile cannot be the shipped pack")
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
        let shipped = try CasePack.shipped()
        // The same pack with every counter-example turned into a positive: the
        // rule that refuses it must be the kind check, not the size check, so
        // breaking that guard cannot leave this test green.
        let flattened = CasePack(schemaVersion: shipped.schemaVersion, id: shipped.id, version: shipped.version,
                                 cases: shipped.cases.map { Self.copy($0, kind: .positive) })
        #expect(Set(flattened.cases.map(\.kind)) == [.positive])
        var rejected = false
        do { try CasePack.check(flattened) } catch { rejected = true }
        #expect(rejected, "a pack that only teaches easy cases must not ship")
    }

    @Test("negatives without a conflict or a refusal are refused")
    func conflictKindIsRequired() throws {
        let shipped = try CasePack.shipped()
        let rest = shipped.cases.filter { $0.kind != .conflict && $0.kind != .refusal }
        // Large enough to clear the size and coverage guards on its own, so the
        // only rule left standing is the one under test.
        #expect(rest.count >= 20)
        #expect(Set(rest.map(\.kind)).contains(.negative))
        let pack = CasePack(schemaVersion: shipped.schemaVersion, id: shipped.id, version: shipped.version,
                             cases: rest)
        var rejected = false
        do { try CasePack.check(pack) } catch { rejected = true }
        #expect(rejected, "a counter-example has to include a conflict or a refusal")
    }

    /// One sample with a different kind, so a rule can be isolated without
    /// inventing a whole pack by hand.
    private static func copy(_ sample: CasePack.Sample, kind: CasePack.Sample.Kind) -> CasePack.Sample {
        CasePack.Sample(caseID: sample.caseID, kind: kind, scenario: sample.scenario, profiles: sample.profiles,
                        input: sample.input, expected: sample.expected, whyNot: sample.whyNot,
                        evidenceLevel: sample.evidenceLevel, sourceVersion: sample.sourceVersion,
                        review: sample.review)
    }
}
