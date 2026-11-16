import CryptoKit
import Foundation

/// Writes an eligibility report as a path-free JSON artifact.
///
/// The report exists so a filtered Manifest's omissions are legible
/// (SPEC v0.1.2 §10.1-5): the records that did not enter Mapping are named by
/// id, decision and rule, never by path.
///
/// It is written beside the run it explains and never over an existing file
/// with different content — two contradictory reports sharing one path would
/// make both unusable as evidence.
public enum EligibilityReportExport {
    public static let reportFile = "eligibility-report.json"

    public struct Written: Codable, Sendable, Equatable {
        public let file: String
        public let sha256: String
        public let bytes: Int
    }

    @discardableResult
    public static func write(_ report: EligibilityReport, to directory: URL) throws -> Written {
        let data = try FormaJSON.encode(report, pretty: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(reportFile)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try? Data(contentsOf: url)
            // Rewriting identical bytes is harmless; rewriting different bytes
            // would replace one piece of evidence with another.
            if existing != data { throw FormaError.sourceChanged }
        } else {
            try data.write(to: url, options: .atomic)
        }
        return Written(file: reportFile, sha256: SHA256.hash(data: data).hexadecimalDigest,
                       bytes: data.count)
    }
}
