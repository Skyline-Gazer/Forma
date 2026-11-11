import Foundation
import OSLog

public enum FormaError: Error, LocalizedError, Sendable, Equatable {
    case unavailable, cancelled, invalidResponse, timeout, disconnected
    case unauthorized, incompatible, credentialMissing, storage, invalidSource
    case sourceChanged, hydrationPending, network, remoteStatus(Int), refused, invalidOutput

    public var code: String {
        switch self {
        case .unavailable: "unavailable"
        case .cancelled: "cancelled"
        case .invalidResponse: "invalid_response"
        case .timeout: "timeout"
        case .disconnected: "disconnected"
        case .unauthorized: "unauthorized"
        case .incompatible: "incompatible"
        case .credentialMissing: "credential_missing"
        case .storage: "storage"
        case .invalidSource: "invalid_source"
        case .sourceChanged: "source_changed"
        case .hydrationPending: "hydration_pending"
        case .network: "network"
        case .remoteStatus: "remote_status"
        case .refused: "refused"
        case .invalidOutput: "invalid_output"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The requested resource is unavailable."
        case .cancelled: "The operation was cancelled."
        case .invalidResponse: "The service returned an invalid response."
        case .timeout: "The operation timed out."
        case .disconnected: "The service disconnected."
        case .unauthorized: "This operation requires explicit authorization."
        case .incompatible: "The detected service capability is incompatible."
        case .credentialMissing: "Save an API key in Keychain before running the probe."
        case .storage: "Forma could not access its local storage."
        case .invalidSource: "The selected source cannot be safely accessed."
        case .sourceChanged: "The source changed. Scan it again before reading."
        case .hydrationPending: "The file content is not available locally."
        case .network: "Forma could not reach the service."
        case .remoteStatus(let status): "The service returned HTTP \(status)."
        case .refused: "The model refused the probe."
        case .invalidOutput: "The model output did not satisfy the probe schema."
        }
    }
}

public enum FormaDiagnostics {
    public enum Operation: String, Sendable {
        case openWorkspace, registerSource, scanSource, readEvidence, discoverMCP, providerProbe, saveCredential
        /// A correction click that failed before FormaCore could judge it -
        /// the store refused the write, or the manifest it was aimed at had
        /// been superseded. Not a refusal: a decision FormaCore declined on the
        /// evidence is a successful call whose row carries
        /// `reviewState == .rejected`, and the review screen reads it from the
        /// table, which is the audit trail. This case exists so a lost click and
        /// a refused one are not the same line in the log.
        case applyCorrection
    }

    private static let logger = Logger(subsystem: "io.github.skyline-gazer.forma", category: "operations")

    public static func failure(_ operation: Operation, _ error: FormaError) {
        logger.error("operation=\(operation.rawValue, privacy: .public) code=\(error.code, privacy: .public)")
    }

    /// A database constraint refused a write, named by the constraint. The
    /// published `FormaError` vocabulary has no case for this and must not
    /// grow one for a state no reviewer can cause, so the distinction lives
    /// here instead: `storage` tells the caller something was refused, this
    /// tells whoever reads the log which rule did it.
    public static func constraintConflict(_ operation: Operation, _ constraint: String) {
        logger.error("operation=\(operation.rawValue, privacy: .public) code=\(FormaError.storage.code, privacy: .public) constraint=\(constraint, privacy: .public)")
    }
}
