import CryptoKit
import Foundation
import Testing
@testable import FormaCore

/// Diagnostics must be useful without becoming a leak.
///
/// The canary values below stand in for the things a support bundle must never
/// contain: a credential, a customer name, a record UUID, an absolute path and a
/// document excerpt.
private enum Canary {
    static let credential = "sk-canary0123456789abcdef"
    static let customer = "CANARY-CUSTOMER-NAME"
    static let uuid = "9F1C2D3E-4A5B-4C6D-8E7F-0A1B2C3D4E5F"
    static let path = "/Users/canary/Documents/Customer Quote 2026.pdf"
    static let body = "CANARY BODY TEXT that must never be logged"

    static var all: [String] { [credential, customer, uuid, path, body] }

    static var mixed: String {
        "authorization: \(credential) for \(customer) record \(uuid) at \(path) body: \(body)"
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    // MARK: - Redaction

    @Test("redaction removes credentials, UUIDs, paths and e-mail addresses")
    func redactionRemovesRecognisableShapes() {
        let redacted = DiagnosticsRedactor.redact(Canary.mixed)

        #expect(redacted.contains(Canary.credential) == false)
        #expect(redacted.contains(Canary.uuid) == false)
        #expect(redacted.contains(Canary.path) == false)
        #expect(redacted.contains("<credential>"))
        #expect(redacted.contains("<uuid>"))
        #expect(redacted.contains("<path>"))
        #expect(DiagnosticsRedactor.redact("mail me at someone@example.com")
            .contains("<email>"))
    }

    @Test("redaction never turns a diagnosis into an empty line")
    func redactionKeepsStructure() {
        let text = "stage=mcp_call code=disconnected path=\(Canary.path)"
        let redacted = DiagnosticsRedactor.redact(text)
        #expect(redacted.hasPrefix("stage=mcp_call code=disconnected"))
        #expect(redacted.contains("<path>"))
    }

    // MARK: - The report cannot carry raw stderr

    @Test("a report carries a stderr digest, never the stderr text")
    func reportNeverContainsRawStderrText() throws {
        let capture = StderrCapture(limit: 4_096)
        capture.append(Data(Canary.mixed.utf8))
        let snapshot = capture.snapshot()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = DiagnosticsReport(
            generatedAt: now, applicationVersion: "0.1.0",
            events: [DiagnosticEvent(at: now, stage: .mcpCall, code: .disconnected,
                                     connection: .init(channel: "read", generation: 2,
                                                       connected: false, consecutiveFailures: 1,
                                                       exhausted: false))],
            stderr: ["read": snapshot])

        let authorization = DiagnosticsExportAuthorization(
            authorizedBy: "owner", purpose: "support review", issuedAt: now)
        let rendered = try report.render(authorization: authorization, at: now)

        for canary in Canary.all {
            #expect(rendered.contains(canary) == false, "leaked \(canary)")
        }
        #expect(rendered.contains("sha256=\(snapshot.sha256)"))
        #expect(rendered.contains("bytes=\(snapshot.byteCount)"))
        #expect(rendered.contains("channel=read"))
    }

    // MARK: - Export authorization

    @Test("an export without who-and-why is refused")
    func exportRequiresACompleteAuthorization() {
        let report = DiagnosticsReport(generatedAt: Date(), applicationVersion: "0.1.0", events: [])
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(throws: DiagnosticsExportError.incompleteAuthorization) {
            try report.render(authorization: .init(authorizedBy: " ", purpose: "support",
                                                   issuedAt: now), at: now)
        }
        #expect(throws: DiagnosticsExportError.incompleteAuthorization) {
            try report.render(authorization: .init(authorizedBy: "owner", purpose: "",
                                                   issuedAt: now), at: now)
        }
        #expect(throws: DiagnosticsExportError.expired) {
            try report.render(authorization: .init(authorizedBy: "owner", purpose: "support",
                                                   issuedAt: now,
                                                   expiresAt: now.addingTimeInterval(-1)), at: now)
        }
    }

    @Test("a rendered report names only stages, codes and counts")
    func eventsRenderOnlyWhitelistedValues() throws {
        let event = DiagnosticEvent(
            at: Date(timeIntervalSince1970: 0), stage: .mcpReconnect, code: .exhausted,
            attempt: 3,
            connection: .init(channel: "write", generation: 4, connected: false,
                              consecutiveFailures: 3, exhausted: true))
        #expect(event.rendered ==
            "stage=mcp_reconnect code=exhausted attempt=3 channel=write generation=4 "
            + "connected=0 failures=3 exhausted=1")

        // A non-Forma error collapses to `unknown`; its text is never carried.
        struct Foreign: Error { let text = Canary.body }
        let foreign = DiagnosticEvent(at: Date(), stage: .mcpCall, code: DiagnosticCode(thrown: Foreign()))
        #expect(foreign.code == .unknown)
        #expect(foreign.rendered.contains(Canary.body) == false)
    }

    // MARK: - Bounds

    @Test("the event log keeps a bounded tail")
    func logIsBounded() async {
        let log = DiagnosticLog(capacity: 10)
        for index in 0..<1_000 {
            await log.record(stage: .mcpCall, code: .ok, at: Date(timeIntervalSince1970: Double(index)),
                             attempt: index)
        }
        let events = await log.snapshot()
        #expect(events.count == 10)
        #expect(events.last?.attempt == 999)
        #expect(await log.count() == 10)
    }

    @Test("stderr capture keeps a bounded tail and digests everything")
    func stderrCaptureIsBoundedAndDigestIsStable() {
        let capture = StderrCapture(limit: 8)
        let payload = Data("0123456789abcdefghijklmnopqrstuv".utf8)
        capture.append(payload)

        let snapshot = capture.snapshot()
        #expect(snapshot.byteCount == payload.count)
        #expect(snapshot.retainedBytes == 8)
        #expect(snapshot.truncated)
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(snapshot.sha256 == expected)
        // The tail is what a developer would want to look at, on this machine.
        #expect(capture.localBytes() == Data(payload.suffix(8)))

        // A second capture with the same bytes reports the same digest.
        let twin = StderrCapture(limit: 8)
        twin.append(payload)
        #expect(twin.snapshot() == snapshot)
        #expect(StderrCapture(limit: 8).snapshot() == .empty)
    }
}
