import Foundation
import Testing

@testable import FormaCore

/// The metrics doc names the test that pins each property, which is only worth doing if
/// those names stay true: a renamed case would leave the doc asserting a guarantee that
/// nothing checks. This suite reads the doc and the test sources at their compile-time
/// paths and fails on the first name that resolves to nothing.
@Suite("Documentation integrity")
struct DocumentationIntegrityTests {
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

    private static func testSources() throws -> [String] {
        let root = Self.repositoryRoot.appendingPathComponent("Tests/FormaCoreTests")
        return try Self.collectSwift(under: root).map { try String(contentsOf: $0, encoding: .utf8) }
    }

    private static func sourceText() throws -> String {
        let root = repositoryRoot.appendingPathComponent("Sources/FormaCore")
        let files = try collectSwift(under: root)
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private static func collectSwift(under root: URL) throws -> [URL] {
        let found = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try found.flatMap { item -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { return [] }
            if isDirectory.boolValue { return try collectSwift(under: item) }
            return item.pathExtension == "swift" ? [item] : []
        }
    }

    @Test("every test the doc names still exists")
    func docNamesResolveToTests() throws {
        let doc = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("docs/EVALUATION-METRICS.md"),
            encoding: .utf8)
        let sources = try Self.testSources().joined(separator: "\n")
        let code = try Self.sourceText()
        // Any backticked name that is neither a type/member of the code nor a test is
        // suspect; only the second half of that is checked here, because a name that
        // exists nowhere at all is already caught by the audit that reads Sources too.
        // A name may arrive bare (`voidingIsOrderIndependent`) or qualified
        // (`EvaluationMetricsTests.voidingIsOrderIndependent`); both name the same func.
        let named = Set(doc.split(separator: "`").enumerated()
            .filter { $0.offset.isMultiple(of: 2) == false }
            .map(\.element)
            .map(String.init)
            .map { $0.split(separator: ".").last.map(String.init) ?? $0 }
            .filter { Self.looksLikeTestName($0) })
        let candidates = named.filter { !code.contains($0) }
        let missing = candidates.filter { !sources.contains("func \($0)(") }
        #expect(missing.isEmpty, "named in the doc but defined nowhere: \(missing.sorted())")
        // A doc that stopped naming tests would make the assertions above vacuous.
        #expect(candidates.count >= 8, "only \(candidates.count) test-like names were parsed")
    }

    private static func looksLikeTestName(_ name: String) -> Bool {
        guard name.count >= 10, name.first?.isLowercase == true, !name.contains(where: \.isWhitespace)
        else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber }
    }
}