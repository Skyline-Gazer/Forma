import CryptoKit
import Foundation
import Testing

@testable import FormaCore

/// The Issue #51 gate "copyright/license takes precedence over feature
/// completion" is only real if it is executable. This suite recomputes the
/// facts `docs/IMPORT-ELIGIBILITY-LICENSE-AUDIT.md` asserts about: the
/// reviewed dependency set (nothing GPL/AGPL, nothing floating), the shipped
/// policy identity (one reviewed byte sequence), the rule inventory (the
/// audit table is the policy, not a prose memory of it), and the provenance
/// boundary (Mole is named in docs only, never in the build inputs).
///
/// A failure here is a licensing finding, not a flaky test: fix by restoring
/// the reviewed state or by re-reviewing and updating the audit document in
/// the same change.
@Suite("Eligibility license audit")
struct EligibilityLicenseAuditTests {
    private static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("docs").path) {
                return url
            }
        }
        fatalError("could not walk up to the repository root from #filePath")
    }

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The digest of the policy this audit reviewed (canonicalData SHA-256:
    /// rules in classifier order, keys sorted, compact). See audit §4.
    private static let reviewedPolicyDigest =
        "aa7796dfe21d3eca6b0030f39cb1cb5f95c26c8cfab6069910bc4baad54d2a57"

    // MARK: - Dependencies

    @Test("dependencies stay inside the reviewed permissive exact-pinned set")
    func reviewedDependencySet() throws {
        let manifest = try Self.read("Package.swift")
        let pattern = #"\.package\(url: "([^"]+)", exact: "([^"]+)"\)"#
        let declared = Self.matches(pattern, in: manifest)
            .map { "\($0[0])@\($0[1])" }
            .sorted()
        // Every package() line must use the exact-pin form; a `.from:`/`upToNext`
        // addition would evade this allow-list entirely.
        let packageLines = manifest
            .split(separator: "\n")
            .filter { $0.contains(".package(url:") }
            .count
        #expect(declared.count == packageLines,
                "a dependency declared without `exact:` is not auditable")
        #expect(declared == [
            "https://github.com/groue/GRDB.swift.git@7.8.0",
            "https://github.com/objecthub/swift-dynamicjson@2.0.1",
            "https://github.com/weichsel/ZIPFoundation.git@0.9.20",
        ], "the declared dependency set drifted from the reviewed MIT/MIT/Apache-2.0 graph")

        // Package.resolved must pin the same locations and versions — the graph
        // that CI actually fetches, not just the manifest's intent.
        let resolvedText = try Self.read("Package.resolved")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(resolvedText.utf8)) as? [String: Any])
        let pins = try #require(root["pins"] as? [[String: Any]])
        let pinSet = pins.compactMap { pin -> String? in
            guard let location = pin["location"] as? String,
                  let version = (pin["state"] as? [String: Any])?["version"] as? String
            else { return nil }
            return "\(location)@\(version)"
        }.sorted()
        #expect(pinSet == [
            "https://github.com/groue/GRDB.swift.git@7.8.0",
            "https://github.com/objecthub/swift-dynamicjson@2.0.1",
            "https://github.com/weichsel/ZIPFoundation.git@0.9.20",
        ], "Package.resolved drifted from the reviewed set")
        for pin in pins {
            let state = try #require(pin["state"] as? [String: Any])
            #expect(state["version"] != nil && state["branch"] == nil,
                    "\(pin["identity"] ?? "?") is pinned to a branch, not a released version")
        }
    }

    @Test("the shipped policy digest is pinned in the audit document")
    func pinnedPolicyDigest() throws {
        let policy = try EligibilityPolicy.shipped()
        #expect(policy.digest == Self.reviewedPolicyDigest,
                "the shipped policy changed bytes; bump policy_version and update the audit doc in this change")
        let audit = try Self.read("docs/IMPORT-ELIGIBILITY-LICENSE-AUDIT.md")
        #expect(audit.contains(Self.reviewedPolicyDigest),
                "the audit document no longer records the digest this suite pins")
        #expect(policy.policyVersion == "eligibility.v2")
    }

    @Test("the audit rule table is the shipped rule inventory, row for row")
    func auditTableMatchesPolicy() throws {
        let policy = try EligibilityPolicy.shipped()
        let audit = try Self.read("docs/IMPORT-ELIGIBILITY-LICENSE-AUDIT.md")
        let rows = audit.split(separator: "\n").compactMap { line -> (String, String, String)? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5, Int(cells[1]) != nil else { return nil }
            let ruleID = cells[2].replacingOccurrences(of: "`", with: "")
            let decision = cells[3]
            // Strength cells may carry an annotation ("strong（需…）"); the first word is the strength.
            let strength = cells[4].split(whereSeparator: { $0 == " " || $0 == "（" }).first.map(String.init) ?? ""
            return (ruleID, decision, strength)
        }
        let expected = policy.orderedRules.map { ($0.ruleID, $0.decision.rawValue, $0.evidenceStrength.rawValue) }
        #expect(rows.count == expected.count,
                "the audit table lost or gained rows against the shipped policy")
        for (row, rule) in zip(rows, expected) {
            #expect(row.0 == rule.0)
            #expect(row.1 == rule.1)
            #expect(row.2 == rule.2)
        }
    }

    // MARK: - Provenance boundary

    @Test("the upstream reference never enters build inputs")
    func provenanceStaysInDocs() throws {
        // Attribution lives in docs only; code, tests and policy data must not
        // carry upstream identifiers, and no upstream file shape may appear.
        // The needles are built at runtime so this file's own text cannot
        // self-trigger the check it performs.
        let author = ["t", "w", "9", "3"].joined() + "/" + ["M", "o", "l", "e"].joined()
        let upstreamFile = ["purge", "_", "shared"].joined()
        for directory in ["Sources", "Tests"] {
            for file in Self.collectFiles(under: Self.repositoryRoot.appendingPathComponent(directory)) {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                #expect(!text.contains(author), "\(file.lastPathComponent) names the upstream author outside docs")
                #expect(!text.contains(upstreamFile), "\(file.lastPathComponent) carries upstream file names")
            }
        }
        let shellUnderSources = Self.collectFiles(under: Self.repositoryRoot.appendingPathComponent("Sources"),
                                                  ext: "sh")
        #expect(shellUnderSources.isEmpty, "shell logic does not belong in Forma's build inputs")
    }

    // MARK: - Helpers

    private static func collectFiles(under root: URL, ext: String = "swift") -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return found.flatMap { item -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { return [] }
            if isDirectory.boolValue { return collectFiles(under: item, ext: ext) }
            return item.pathExtension == ext ? [item] : []
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            match.numberOfRanges > 1 ? (1..<match.numberOfRanges).map { group in
                Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
            } : []
        }.filter { !$0.isEmpty }
    }
}
