import CryptoKit
import Foundation

/// The target an import run may write to, stated by the operator.
///
/// It is a value, not a name lookup: the database is addressed by UUID, and the
/// operator has to say out loud that the database is disposable. A target that
/// merely "looks like" a test database does not qualify.
public struct ImportIsolatedTarget: Sendable, Equatable {
    /// Canonical uppercase UUID string — the form the read adapter reports and
    /// the form the executor compares against.
    public let databaseID: String
    public let databaseName: String
    public let groupPath: [String]
    /// The operator's explicit statement that this database was created for this
    /// run and may be written to.
    public let declaredDisposable: Bool

    public init(databaseID: String, databaseName: String, groupPath: [String],
                declaredDisposable: Bool) {
        self.databaseID = databaseID
        self.databaseName = databaseName
        self.groupPath = groupPath
        self.declaredDisposable = declaredDisposable
    }
}

/// Everything a run must be handed before it may write.
///
/// This type is the only way to reach the write path, and it cannot be derived
/// from a manifest: `ManifestEnvelope` has no field that produces one, and the
/// eligibility decision `INCLUDE` is not consulted anywhere here. The scope it
/// carries is the boundary's own default-deny scope, so the two agree by
/// construction rather than by convention.
public struct ImportRuntimeAuthorization: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Planning only: the runtime reports what it would do and writes nothing.
        case planOnly
        /// Writes are allowed, still bounded by `scope`.
        case write
    }

    public let mode: Mode
    public let target: ImportIsolatedTarget
    public let scope: ImportWriteScope
    public let contract: DEVONthinkWriteToolContract
    public let authorizedBy: String
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(mode: Mode, target: ImportIsolatedTarget, scope: ImportWriteScope,
                contract: DEVONthinkWriteToolContract = .i1B2Baseline,
                authorizedBy: String, issuedAt: Date, expiresAt: Date? = nil) {
        self.mode = mode
        self.target = target
        self.scope = scope
        self.contract = contract
        self.authorizedBy = authorizedBy
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// A digest of the whole authorization. Two runs under different terms have
    /// different digests, and the ledger records which one an operation used.
    public var digest: String {
        let text = [
            mode.rawValue, target.databaseID.uppercased(), target.databaseName,
            target.groupPath.joined(separator: "/"), target.declaredDisposable ? "disposable" : "shared",
            scope.databaseID.uppercased(), scope.groupPrefix.joined(separator: "/"),
            scope.tools.map(\.rawValue).sorted().joined(separator: ","),
            scope.metadataIdentifiers.sorted().joined(separator: ","),
            String(scope.recordLimit), String(scope.groupLimit),
            contract.digests.keys.sorted().map { "\($0)=\(contract.digests[$0] ?? "")" }.joined(separator: ","),
            authorizedBy, String(issuedAt.timeIntervalSince1970),
            expiresAt.map { String($0.timeIntervalSince1970) } ?? "none",
        ].joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why the runtime stopped before doing anything.
public enum ImportRuntimeRefusalCode: String, Codable, Sendable, CaseIterable {
    case targetNotDisposable = "target_not_disposable"
    case productionTarget = "production_target"
    case malformedTarget = "malformed_target"
    case scopeDoesNotMatchTarget = "scope_does_not_match_target"
    case writeModeNotAuthorized = "write_mode_not_authorized"
    case authorizationExpired = "authorization_expired"
    case authorizationAlreadyUsed = "authorization_already_used"
    case noRequests = "no_requests"
    case requestTargetMismatch = "request_target_mismatch"
    case executionFailed = "execution_failed"
}

public struct ImportRuntimeRefusal: Sendable, Equatable {
    public let code: ImportRuntimeRefusalCode
    /// Non-sensitive: no paths, no field values, no UUIDs.
    public let detail: String

    public init(_ code: ImportRuntimeRefusalCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// One planned operation. It is deliberately the same shape as the ledger row so
/// the plan can be compared with what the run did.
public struct ImportPlanEntry: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        /// The key already exists: the executor would return the recorded state.
        case alreadyRecorded = "already_recorded"
        /// The clearance did not pass; the executor would not write.
        case blocked
        /// Everything needed is present.
        case wouldExecute = "would_execute"
    }

    public let keyDigest: String
    public let action: Action
    public let recordedPhase: ImportPhase?
    public let blockingCodes: [ImportPreflightCode]

    public init(keyDigest: String, action: Action, recordedPhase: ImportPhase?,
                blockingCodes: [ImportPreflightCode]) {
        self.keyDigest = keyDigest
        self.action = action
        self.recordedPhase = recordedPhase
        self.blockingCodes = blockingCodes
    }
}

public struct ImportRunPlan: Sendable, Equatable {
    public let mode: ImportRuntimeAuthorization.Mode
    public let entries: [ImportPlanEntry]
    public let refusals: [ImportRuntimeRefusal]

    public var willWrite: Bool {
        mode == .write && refusals.isEmpty && entries.contains { $0.action == .wouldExecute }
    }
}

public struct ImportRunOutcome: Sendable, Equatable {
    public let mode: ImportRuntimeAuthorization.Mode
    public let refusals: [ImportRuntimeRefusal]
    public let results: [ImportExecutionResult]

    public var wroteAnything: Bool { results.contains { $0.attempts > 0 } }
}

/// The write side of one run: the guarded surface, its budget and its lifetime.
struct ImportWriteSession: Sendable {
    let surface: any ImportWriteSurface
    let authorization: ImportWriteAuthorization
    let close: @Sendable () async -> Void
}

/// The only entry point that can execute an import.
///
/// It exists to make three things structural rather than remembered:
///
/// 1. **No authorization, no write.** `execute` takes the authorization as a
///    parameter; there is no default, and `INCLUDE` in a manifest cannot produce
///    one.
/// 2. **One authorization, one run.** A second `execute` with the same
///    authorization digest is refused, so a repeated call cannot spend a fresh
///    budget against an exhausted one.
/// 3. **Nothing runs at launch.** The type has no timers, no observers and no
///    startup hook; it does something only when a caller with an authorization
///    asks it to.
public actor ImportRuntime {
    private let ledger: ImportLedger
    private let writer: ImportSingleWriter
    private let read: any ImportReadTransport
    private let makeSession: @Sendable (ImportRuntimeAuthorization) -> ImportWriteSession
    private let clock: @Sendable () -> Date
    /// Reserved production names. A database with one of these names is never a
    /// valid target, whatever UUID it was addressed by.
    static let reservedProductionNames: Set<String> = ["project_archive"]
    private var usedAuthorizations: Set<String> = []

    public init(ledger: ImportLedger, writer: ImportSingleWriter, read: any ImportReadTransport,
                sourceRoot: URL, approvedSourcePaths: Set<String>,
                clock: @escaping @Sendable () -> Date = Date.init) {
        let approved = Set(approvedSourcePaths.map { ImportWriteScope.canonical($0) })
        let root = sourceRoot.standardizedFileURL
        self.init(ledger: ledger, writer: writer, read: read, clock: clock) { authorization in
            let surface = DEVONthinkMCPWriteTransport(sourceRoot: root)
            let guardAuthorization = ImportWriteAuthorization(scope: authorization.scope, clock: clock)
            let guarded = GuardedImportWriteTransport(
                base: surface, authorization: guardAuthorization,
                sourcePath: { binding in
                    let path = root.appendingPathComponent(binding.relativePath).standardizedFileURL.path
                    return approved.contains(path) ? path : nil
                })
            return ImportWriteSession(surface: guarded, authorization: guardAuthorization,
                                      close: { await surface.close() })
        }
    }

    init(ledger: ImportLedger, writer: ImportSingleWriter, read: any ImportReadTransport,
         clock: @escaping @Sendable () -> Date = Date.init,
         makeSession: @escaping @Sendable (ImportRuntimeAuthorization) -> ImportWriteSession) {
        self.ledger = ledger
        self.writer = writer
        self.read = read
        self.clock = clock
        self.makeSession = makeSession
    }

    // MARK: - Planning

    /// Reports what a run would do. It never opens a connection and never writes.
    public func plan(_ requests: [ImportRuntimeRequest],
                     authorization: ImportRuntimeAuthorization? = nil) throws -> ImportRunPlan {
        var refusals = authorization.map { Self.refusals(for: $0, at: clock()) } ?? []
        if let authorization {
            refusals.append(contentsOf: Self.requestRefusals(requests, authorization: authorization))
        }
        if requests.isEmpty {
            refusals.append(.init(.noRequests, detail: "the run contains no operations"))
        }
        let entries = try requests.map { request -> ImportPlanEntry in
            if let stored = try ledger.operation(keyDigest: request.intent.key.digest) {
                return ImportPlanEntry(keyDigest: stored.keyDigest, action: .alreadyRecorded,
                                       recordedPhase: stored.phase, blockingCodes: [])
            }
            guard request.clearance.verdict == .pass else {
                return ImportPlanEntry(keyDigest: request.intent.key.digest, action: .blocked,
                                       recordedPhase: nil,
                                       blockingCodes: request.clearance.blockingCodes)
            }
            return ImportPlanEntry(keyDigest: request.intent.key.digest, action: .wouldExecute,
                                   recordedPhase: nil, blockingCodes: [])
        }
        return ImportRunPlan(mode: authorization?.mode ?? .planOnly, entries: entries,
                             refusals: refusals)
    }

    // MARK: - Execution

    /// Runs the requests under the authorization.
    ///
    /// Every refusal happens before a surface is built, and the surface is closed
    /// on every exit path.
    public func execute(_ requests: [ImportRuntimeRequest],
                        authorization: ImportRuntimeAuthorization) async throws -> ImportRunOutcome {
        let mode = authorization.mode
        var refusals = Self.refusals(for: authorization, at: clock())
        refusals.append(contentsOf: Self.requestRefusals(requests, authorization: authorization))
        if requests.isEmpty {
            refusals.append(.init(.noRequests, detail: "the run contains no operations"))
        }
        guard refusals.isEmpty else {
            return ImportRunOutcome(mode: mode, refusals: refusals, results: [])
        }
        guard authorization.mode == .write else {
            return ImportRunOutcome(
                mode: mode,
                refusals: [.init(.writeModeNotAuthorized,
                                 detail: "the authorization allows planning only")],
                results: [])
        }
        guard usedAuthorizations.insert(authorization.digest).inserted else {
            return ImportRunOutcome(
                mode: mode,
                refusals: [.init(.authorizationAlreadyUsed,
                                 detail: "this authorization has already been used for a run")],
                results: [])
        }

        let session = makeSession(authorization)
        var results: [ImportExecutionResult] = []
        do {
            let executor = ImportExecutor(ledger: ledger, writer: writer,
                                          write: session.surface, read: read, clock: clock)
            for request in requests {
                try Task.checkCancellation()
                do {
                    results.append(try await executor.execute(request.intent,
                                                              clearance: request.clearance))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The executor already recorded whatever it knew. Stopping
                    // here is the fail-closed answer: later operations have not
                    // been attempted, so their keys stay unrecorded.
                    refusals.append(.init(.executionFailed, detail: Self.code(for: error)))
                    break
                }
            }
        } catch is CancellationError {
            await session.close()
            throw CancellationError()
        }
        await session.close()
        return ImportRunOutcome(mode: mode, refusals: refusals, results: results)
    }

    // MARK: - Authorization checks

    /// Every reason this authorization may not write, in a stable order.
    static func refusals(for authorization: ImportRuntimeAuthorization,
                         at date: Date) -> [ImportRuntimeRefusal] {
        var refusals: [ImportRuntimeRefusal] = []
        let target = authorization.target
        if UUID(uuidString: target.databaseID) == nil {
            refusals.append(.init(.malformedTarget, detail: "the target database id is not a UUID"))
        }
        if target.groupPath.isEmpty || target.groupPath.contains(where: { $0.isEmpty }) {
            refusals.append(.init(.malformedTarget, detail: "the target group path is empty"))
        }
        if !target.declaredDisposable {
            refusals.append(.init(.targetNotDisposable,
                                  detail: "the target was not declared disposable"))
        }
        if reservedProductionNames.contains(target.databaseName.lowercased()) {
            refusals.append(.init(.productionTarget,
                                  detail: "the target database is the reserved production database"))
        }
        let scope = authorization.scope
        if scope.databaseID.uppercased() != target.databaseID.uppercased()
            || scope.groupPrefix != target.groupPath {
            refusals.append(.init(.scopeDoesNotMatchTarget,
                                  detail: "the write scope does not address the authorized target"))
        }
        if let expiresAt = authorization.expiresAt, expiresAt <= date {
            refusals.append(.init(.authorizationExpired, detail: "the authorization has expired"))
        }
        return refusals
    }

    /// Every request must address the authorized target.
    ///
    /// The executor compares the target group and database with what it reads
    /// back, but it would happily *attempt* an operation aimed somewhere else.
    /// This check refuses the run before a surface exists, so an intent that
    /// names another database cannot borrow this authorization.
    static func requestRefusals(_ requests: [ImportRuntimeRequest],
                                authorization: ImportRuntimeAuthorization) -> [ImportRuntimeRefusal] {
        let target = authorization.target
        for request in requests {
            let intent = request.intent
            guard intent.targetDatabase.uppercased() == target.databaseID.uppercased(),
                  intent.groupPath == target.groupPath else {
                return [.init(.requestTargetMismatch,
                              detail: "an operation addresses a target outside the authorization")]
            }
            guard request.clearance.binding.targetDatabase.uppercased()
                    == target.databaseID.uppercased(),
                  request.clearance.binding.targetGroupPath == target.groupPath else {
                return [.init(.requestTargetMismatch,
                              detail: "a clearance was decided for a different target")]
            }
        }
        return []
    }

    private static func code(for error: any Error) -> String {
        (error as? FormaError)?.code ?? "unknown_error"
    }
}

/// One operation, with the clearance that was decided for it.
///
/// The intent carries its own key, source binding and target; the clearance is
/// the preflight verdict bound to those same facts. Neither can substitute for
/// the authorization, which lives on the runtime call.
public struct ImportRuntimeRequest: Sendable {
    public let intent: ImportIntent
    public let clearance: ImportPreflightClearance

    public init(intent: ImportIntent, clearance: ImportPreflightClearance) {
        self.intent = intent
        self.clearance = clearance
    }
}
