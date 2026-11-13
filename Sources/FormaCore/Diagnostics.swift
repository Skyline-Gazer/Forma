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
        /// A provider-egress decision. Only the ticket's digest/version summary
        /// or a denial code is ever logged - never a payload, path or credential.
        case providerEgress
        /// A correction whose call threw - the store refused the write or the
        /// manifest had been superseded. A refusal on the evidence is a
        /// successful call, recorded as a `rejected` row in the table.
        case applyCorrection
    }

    private static let logger = Logger(subsystem: "io.github.skyline-gazer.forma", category: "operations")

    public static func failure(_ operation: Operation, _ error: FormaError) {
        logger.error("operation=\(operation.rawValue, privacy: .public) code=\(error.code, privacy: .public)")
    }

    /// The only egress log line. `EgressTicket.logSummary` and `EgressDenial.code`
    /// are constructed from digests, versions and fixed reason names, so a
    /// canary placed in a document can never reach this string.
    public static func egress(_ decision: EgressDecision) {
        if let ticket = decision.ticket {
            logger.info("operation=providerEgress \(ticket.logSummary, privacy: .public)")
        } else if let denial = decision.denial {
            logger.error("operation=providerEgress code=\(denial.code, privacy: .public)")
        }
    }
}
