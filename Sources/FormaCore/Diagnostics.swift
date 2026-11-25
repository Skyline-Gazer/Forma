import Foundation
import OSLog

public enum FormaError: Error, LocalizedError, Sendable, Equatable {
    case unavailable, cancelled, invalidResponse, timeout, disconnected
    case unauthorized, incompatible, credentialMissing, credentialLocked, storage, invalidSource
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
        case .credentialLocked: "credential_locked"
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

    /// The one place a failure becomes a sentence the user reads (CopyGate
    /// finding 2: the alert button was translated and its content was not).
    /// Machine identifiers stay machine: HTTP codes, provider names and the
    /// probe vocabulary are the diagnostics the SPEC carves out.
    public var errorDescription: String? {
        switch self {
        case .unavailable: "请求的资源当前不可用。"
        case .cancelled: "操作已取消。"
        case .invalidResponse: "服务返回了无效响应。"
        case .timeout: "操作超时。"
        case .disconnected: "服务连接已断开。"
        case .unauthorized: "此操作需要明确授权。"
        case .incompatible: "检测到的服务能力不兼容。"
        case .credentialMissing: "请先在钥匙串中保存 API 密钥，再运行探测。"
        case .credentialLocked: "请解锁登录钥匙串以读取已保存的 API 密钥。"
        case .storage: "Forma 无法访问本地存储。"
        case .invalidSource: "所选来源无法安全访问。"
        case .sourceChanged: "来源已变化，请重新扫描后再读取。"
        case .hydrationPending: "文件内容尚未在本地就绪。"
        case .network: "Forma 无法连接服务。"
        case .remoteStatus(let status): "服务返回 HTTP \(status)。"
        case .refused: "模型拒绝了该探测。"
        case .invalidOutput: "模型输出不满足探测的 schema。"
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
