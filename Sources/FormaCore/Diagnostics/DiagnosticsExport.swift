import Foundation

/// The redaction pass every diagnostic export goes through.
///
/// It removes the shapes that are recognisable without understanding the text:
/// UUIDs, absolute paths, credential-looking tokens and e-mail addresses. It
/// deliberately does **not** promise to recognise a customer name or a sentence
/// from a document, which is why the export never carries free text in the first
/// place — see `DiagnosticsReport`.
public enum DiagnosticsRedactor {
    private struct Rule {
        let pattern: NSRegularExpression
        let replacement: String
    }

    private static let rules: [Rule] = {
        let definitions: [(String, String)] = [
            ("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "<uuid>"),
            ("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}", "bearer <credential>"),
            ("\\bsk-[A-Za-z0-9_-]{8,}", "<credential>"),
            ("(?i)\\b(api[_-]?key|token|secret|password)\\b\\s*[=:]\\s*\\S+", "$1=<credential>"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
            // An absolute path: a slash that starts a token, up to whitespace or
            // a quote. It also covers `/Users/.../Documents/x.pdf` and bundle paths.
            ("(?<![\\w:/])/(?:[^\\s\"'<>|]+)", "<path>"),
        ]
        return definitions.compactMap { pattern, replacement in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(pattern: expression, replacement: replacement)
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.pattern.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.replacement)
        }
        return result
    }
}

/// The explicit permission to write a diagnostic report to disk.
///
/// Diagnostics describe a machine's failures, so exporting them is a deliberate
/// act: the caller has to say who asked for it and why, and the report refuses to
/// render without that statement.
public struct DiagnosticsExportAuthorization: Sendable, Equatable {
    public let authorizedBy: String
    public let purpose: String
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(authorizedBy: String, purpose: String, issuedAt: Date,
                expiresAt: Date? = nil) {
        self.authorizedBy = authorizedBy
        self.purpose = purpose
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public enum DiagnosticsExportError: Error, Equatable {
    /// The authorization does not say who asked or why.
    case incompleteAuthorization
    case expired
}

/// What an export contains: structured events and stream digests.
///
/// Raw child stderr is **not** part of this type. It lives in memory for the
/// machine that produced it (`StderrCapture.localBytes()`), and never reaches a
/// file, a log destination or a support bundle.
public struct DiagnosticsReport: Sendable, Equatable {
    public let generatedAt: Date
    public let applicationVersion: String
    public let events: [DiagnosticEvent]
    /// Channel name to that channel's captured-stream summary.
    public let stderr: [String: StderrSnapshot]

    public init(generatedAt: Date, applicationVersion: String, events: [DiagnosticEvent],
                stderr: [String: StderrSnapshot] = [:]) {
        self.generatedAt = generatedAt
        self.applicationVersion = applicationVersion
        self.events = events
        self.stderr = stderr
    }

    /// Renders the report and re-runs redaction over the whole text.
    ///
    /// Two guarantees, both testable: no raw stderr text is reachable through
    /// this value, and every line that does get rendered passes the redactor once
    /// more before it is returned.
    public func render(authorization: DiagnosticsExportAuthorization, at now: Date) throws -> String {
        guard !authorization.authorizedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !authorization.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiagnosticsExportError.incompleteAuthorization
        }
        if let expiresAt = authorization.expiresAt, expiresAt <= now {
            throw DiagnosticsExportError.expired
        }

        var lines: [String] = [
            "forma-diagnostics v1",
            "version=\(applicationVersion)",
            "generated=\(ISO8601DateFormatter().string(from: generatedAt))",
            "events=\(events.count)",
        ]
        for event in events {
            lines.append(event.rendered)
        }
        for channel in stderr.keys.sorted() {
            guard let snapshot = stderr[channel] else { continue }
            lines.append(
                "stderr channel=\(channel) bytes=\(snapshot.byteCount) "
                + "retained=\(snapshot.retainedBytes) truncated=\(snapshot.truncated ? 1 : 0) "
                + "sha256=\(snapshot.sha256)")
        }
        return DiagnosticsRedactor.redact(lines.joined(separator: "\n") + "\n")
    }
}
