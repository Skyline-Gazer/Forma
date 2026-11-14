import CryptoKit
import Foundation

/// Where in the run's structure something happened.
///
/// A closed set on purpose: a free-text stage would eventually carry a path, a
/// field name or a record title.
public enum DiagnosticStage: String, Sendable, CaseIterable, Codable {
    case launch
    case workspaceOpen = "workspace_open"
    case recoverySweep = "recovery_sweep"
    case recoveryReview = "recovery_review"
    case mcpStart = "mcp_start"
    case mcpInitialize = "mcp_initialize"
    case mcpToolsList = "mcp_tools_list"
    case mcpCall = "mcp_call"
    case mcpReconnect = "mcp_reconnect"
    case mcpShutdown = "mcp_shutdown"
    case importPlan = "import_plan"
    case importExecute = "import_execute"
    case appTerminate = "app_terminate"
}

/// The only codes a diagnostic line may carry.
///
/// It is a mapping, not a validator: `DiagnosticCode(FormaError)` cannot produce
/// a string outside this set, so no call site can log server text, a response
/// body or an error description.
public enum DiagnosticCode: String, Sendable, CaseIterable, Codable {
    case ok
    case cancelled
    case timeout
    case disconnected
    case unavailable
    case unauthorized
    case incompatible
    case invalidResponse = "invalid_response"
    case refused
    case storage
    case invalidSource = "invalid_source"
    case sourceChanged = "source_changed"
    case hydrationPending = "hydration_pending"
    case network
    case remoteStatus = "remote_status"
    case credentialMissing = "credential_missing"
    case invalidOutput = "invalid_output"
    case exhausted
    case degraded
    case unknown

    public init(_ error: FormaError) {
        switch error {
        case .cancelled: self = .cancelled
        case .timeout: self = .timeout
        case .disconnected: self = .disconnected
        case .unavailable: self = .unavailable
        case .unauthorized: self = .unauthorized
        case .incompatible: self = .incompatible
        case .invalidResponse: self = .invalidResponse
        case .refused: self = .refused
        case .storage: self = .storage
        case .invalidSource: self = .invalidSource
        case .sourceChanged: self = .sourceChanged
        case .hydrationPending: self = .hydrationPending
        case .network: self = .network
        case .remoteStatus: self = .remoteStatus
        case .credentialMissing: self = .credentialMissing
        case .invalidOutput: self = .invalidOutput
        }
    }

    /// A code for anything thrown. A domain that is not `FormaError` collapses
    /// to `unknown`: its text is not allowed to reach a log line.
    public init(thrown error: any Error) {
        guard let forma = error as? FormaError else {
            self = .unknown
            return
        }
        self.init(forma)
    }
}

/// The connection state at the moment of the event, as numbers and flags.
public struct DiagnosticConnectionState: Sendable, Equatable, Codable {
    public let channel: String
    public let generation: Int
    public let connected: Bool
    public let consecutiveFailures: Int
    public let exhausted: Bool

    public init(channel: String, generation: Int, connected: Bool,
                consecutiveFailures: Int, exhausted: Bool) {
        self.channel = channel
        self.generation = generation
        self.connected = connected
        self.consecutiveFailures = consecutiveFailures
        self.exhausted = exhausted
    }
}

/// One structured diagnostic fact.
///
/// There is no free-text field. Everything a reader needs — stage, code, attempt
/// number, connection state — is drawn from a closed set or a bounded integer.
public struct DiagnosticEvent: Sendable, Equatable, Codable {
    public let at: Date
    public let stage: DiagnosticStage
    public let code: DiagnosticCode
    /// Attempt count, already bounded by the caller (`nil` when not applicable).
    public let attempt: Int?
    public let connection: DiagnosticConnectionState?

    public init(at: Date, stage: DiagnosticStage, code: DiagnosticCode,
                attempt: Int? = nil, connection: DiagnosticConnectionState? = nil) {
        self.at = at
        self.stage = stage
        self.code = code
        self.attempt = attempt
        self.connection = connection
    }

    /// A stable one-line rendering. It contains only enum values and integers.
    public var rendered: String {
        var parts = ["stage=\(stage.rawValue)", "code=\(code.rawValue)"]
        if let attempt { parts.append("attempt=\(attempt)") }
        if let connection {
            parts.append("channel=\(connection.channel)")
            parts.append("generation=\(connection.generation)")
            parts.append("connected=\(connection.connected ? 1 : 0)")
            parts.append("failures=\(connection.consecutiveFailures)")
            parts.append("exhausted=\(connection.exhausted ? 1 : 0)")
        }
        return parts.joined(separator: " ")
    }
}

/// A bounded, in-memory event log.
///
/// Bounded so a failure loop cannot grow without limit; in memory so nothing is
/// persisted without an explicit export.
public actor DiagnosticLog {
    public static let defaultCapacity = 512

    private let capacity: Int
    private var events: [DiagnosticEvent] = []

    public init(capacity: Int = DiagnosticLog.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func record(stage: DiagnosticStage, code: DiagnosticCode, at date: Date,
                       attempt: Int? = nil, connection: DiagnosticConnectionState? = nil) {
        record(DiagnosticEvent(at: date, stage: stage, code: code, attempt: attempt,
                               connection: connection))
    }

    public func record(stage: DiagnosticStage, error: any Error, at date: Date,
                       attempt: Int? = nil, connection: DiagnosticConnectionState? = nil) {
        record(DiagnosticEvent(at: date, stage: stage, code: DiagnosticCode(thrown: error),
                               attempt: attempt, connection: connection))
    }

    public func snapshot(limit: Int? = nil) -> [DiagnosticEvent] {
        guard let limit, limit < events.count else { return events }
        return Array(events.suffix(max(limit, 0)))
    }

    public func count() -> Int { events.count }

    public func clear() { events.removeAll() }
}

/// A digest and a byte count for a captured stream. Never the text itself.
public struct StderrSnapshot: Sendable, Equatable, Codable {
    public let byteCount: Int
    public let retainedBytes: Int
    public let truncated: Bool
    /// SHA-256 over every byte received, so two runs can be compared without
    /// keeping either stream.
    public let sha256: String

    public init(byteCount: Int, retainedBytes: Int, truncated: Bool, sha256: String) {
        self.byteCount = byteCount
        self.retainedBytes = retainedBytes
        self.truncated = truncated
        self.sha256 = sha256
    }

    public static let empty = StderrSnapshot(byteCount: 0, retainedBytes: 0,
                                             truncated: false, sha256: "")
}

/// A bounded, memory-only capture of a child's stderr.
///
/// The raw bytes stay here so a developer can look at them on the machine where
/// the failure happened. They are **not** logged and **not** exported: nothing
/// here has proven redaction strong enough for arbitrary server text, so the
/// export carries `StderrSnapshot` (a digest and lengths) instead.
public final class StderrCapture: @unchecked Sendable {
    public static let defaultLimit = 64 * 1024

    private let lock = NSLock()
    private let limit: Int
    private var retained = Data()
    private var received = 0
    private var hasher = SHA256()
    private var truncated = false

    public init(limit: Int = StderrCapture.defaultLimit) {
        self.limit = max(limit, 0)
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        received += data.count
        hasher.update(data: data)
        guard limit > 0 else {
            truncated = true
            return
        }
        retained.append(data)
        if retained.count > limit {
            // Keep the tail: the last lines usually explain why the peer died.
            retained.removeFirst(retained.count - limit)
            truncated = true
        }
    }

    public func snapshot() -> StderrSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StderrSnapshot(byteCount: received, retainedBytes: retained.count,
                              truncated: truncated, sha256: received == 0 ? "" : digest)
    }

    /// Raw bytes, for a developer inspecting this machine. Never exported.
    public func localBytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return retained
    }
}
