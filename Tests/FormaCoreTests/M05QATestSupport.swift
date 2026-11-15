import CryptoKit
import Foundation
import GRDB

@testable import FormaCore

/// A reproducible, offline execution harness for the M05 fault probes.
///
/// It lives in the test target on purpose: it is QA scaffolding, not a user
/// entry point and not a dependency of the app or CLI. It never opens a
/// DEVONthink connection. Every external effect goes to `FakeImportTransport`.
///
/// The three synthetic files are byte-literal, so their SHA-256 values can be
/// recomputed from this file alone. Three distinct source IDs give three
/// independent operation keys. Budgets are the proposal's numbers: 3 imports,
/// 2 groups, 6 metadata calls and 1 metadata call per record.
enum M05QA {
    static let databaseID = "CCCCCCCC-0000-4000-8000-0000000000A5"
    static let databaseName = "Forma_M05_Sandbox"
    static let defaultRunID = "run-qa-01"
    static let groupRoot = "Forma_M05"
    static let sourceRoot = "/tmp/forma-m05-qa"
    static let snapshot = String(repeating: "a", count: 64)
    static let scopeID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A5")!
    static let associationID = UUID(uuidString: "66666666-6666-4666-8666-6666666666A5")!
    static let association = "m05 synthetic association"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let identifiers: Set<String> = [
        "projectname", "documentcategory", "documenttype", "issuer",
        "bidderentity", "endcustomer", "completionyear", "biddeadline",
    ]

    static let limits = ImportWriteBudgetLimits(imports: 3, groups: 2,
                                               metadataCalls: 6,
                                               metadataCallsPerRecord: 1)

    struct SyntheticFile: Sendable, Equatable {
        let name: String
        let sourceID: UUID
        let body: String

        var relativePath: String { "synthetic/\(name)" }
        var absolutePath: String { "\(M05QA.sourceRoot)/\(relativePath)" }
        var bytes: Data { Data(body.utf8) }
        var sha256: String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Byte-literal fixtures. Changing a body changes the digest in the report;
    /// the value is never taken from a file on disk.
    static let files: [SyntheticFile] = [
        SyntheticFile(name: "m05-t1.md",
                      sourceID: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!,
                      body: "# M05 synthetic T1\nprobe=timeout-after-apply\nprojectname=M05-T1\n"),
        SyntheticFile(name: "m05-d2.md",
                      sourceID: UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!,
                      body: "# M05 synthetic D2\nprobe=disconnect-before-apply\nprojectname=M05-D2\n"),
        SyntheticFile(name: "m05-m3.md",
                      sourceID: UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!,
                      body: "# M05 synthetic M3\nprobe=metadata-failure\nprojectname=M05-M3\n"),
    ]

    struct Approval: Sendable, Equatable {
        let runID: String
        let approvedBy: String
        let issuedAt: Date

        static let canonical = Approval(runID: M05QA.defaultRunID,
                                        approvedBy: "synthetic-owner", issuedAt: M05QA.now)
    }

    struct Stack: Sendable {
        let database: DatabaseQueue
        let ledger: ImportLedger
        let transport: FakeImportTransport
        let runtime: ImportRuntime
        let runID: UUID
        let authorization: ImportRuntimeAuthorization
        let scope: ImportWriteScope
        let groupGuard: GuardedImportWriteTransport
        let intents: [ImportIntent]
        let clearances: [ImportPreflightClearance]
        let preflight: ImportAuthorization
    }

    enum Refusal: String, Error, Equatable {
        case noApproval = "no_approval"
        case malformedApproval = "malformed_approval"
    }

    /// Execute is refused unless a caller hands over a well-formed approval.
    static func requireApproval(_ approval: Approval?) throws -> Approval {
        guard let approval else { throw Refusal.noApproval }
        _ = try authorization(approval)
        return approval
    }

    static func groupPath(_ approval: Approval) -> [String] {
        [groupRoot, approval.runID]
    }

    /// The preflight authorization (name/prefix based) whose digest binds the
    /// clearance and the intent. The runtime authorization is a separate object
    /// with its own digest and budget identity.
    static func preflightAuthorization(_ approval: Approval) -> ImportAuthorization {
        ImportAuthorization(databaseName: databaseID, groupPrefix: groupPath(approval),
                            authorizedBy: approval.approvedBy, issuedAt: approval.issuedAt)
    }

    static func scope(prefix: [String]) -> ImportWriteScope {
        ImportWriteScope(
            databaseID: databaseID, groupPrefix: prefix,
            tools: Set(ImportWriteTool.allCases), metadataIdentifiers: identifiers,
            sourcePaths: Set(files.map(\.absolutePath)),
            recordLimit: limits.imports, groupLimit: limits.groups,
            metadataCallLimit: limits.metadataCalls,
            metadataCallsPerRecordLimit: limits.metadataCallsPerRecord)
    }

    static func authorization(_ approval: Approval) throws -> ImportRuntimeAuthorization {
        let id = approval.runID
        guard !id.isEmpty,
              id.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
              approval.approvedBy.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            throw Refusal.malformedApproval
        }
        return ImportRuntimeAuthorization(
            mode: .write,
            target: ImportIsolatedTarget(databaseID: databaseID, databaseName: databaseName,
                                         groupPath: groupPath(approval),
                                         declaredDisposable: true),
            scope: scope(prefix: groupPath(approval)),
            authorizedBy: approval.approvedBy, issuedAt: approval.issuedAt)
    }

    // MARK: - Requests

    static func intent(_ file: SyntheticFile, runID: UUID, approval: Approval,
                       authorizationDigest: String, metadata: [String: String?]) throws -> ImportIntent {
        let key = try ImportOperationKey(
            sourceID: file.sourceID, snapshotFingerprint: snapshot, manifestRevision: 1,
            targetAssociationID: associationID)
        let source = ImportSourceBinding(
            sourceID: file.sourceID, scopeID: scopeID, relativePath: file.relativePath,
            snapshotFingerprint: snapshot, contentSHA256: file.sha256,
            byteCount: Int64(file.bytes.count), readSessionID: "m05-session")
        let entry = ManifestEntry(
            sourceID: file.sourceID, snapshotFingerprint: snapshot, snapshotRevision: 1,
            sourceVersion: 1, relativePath: file.relativePath, state: .validated,
            target: ManifestTarget(databaseName: databaseID,
                                   groupPath: groupPath(approval), resolved: true),
            eligibleForAutoExecution: true)
        return ImportIntent(
            runID: runID, entry: entry, key: key, source: source,
            targetDatabase: databaseID, groupPath: groupPath(approval),
            associationBasis: "\(association)-\(file.name)", metadata: metadata,
            authorizationDigest: authorizationDigest)
    }

    static func clearance(_ intent: ImportIntent,
                          authorization: ImportAuthorization) throws -> ImportPreflightClearance {
        let profile = try MappingProfile.projectArchive()
        let manifest = try ImportFixtures.manifest(revision: intent.key.manifestRevision)
        return ImportPreflight.evaluate(ImportPreflightInput(
            entry: intent.entry, manifest: manifest,
            expectations: ImportExpectations(profileID: profile.profileID,
                                             profileVersion: profile.profileVersion,
                                             schemaVersion: manifest.schemaVersion),
            authorization: authorization,
            source: ImportSourceFacts(state: .present, authorized: true, readable: true,
                                      hydrationPending: false,
                                      snapshotFingerprint: intent.key.snapshotFingerprint,
                                      sha256: intent.source.contentSHA256),
            target: ImportTargetFacts(exists: true, writable: true, availableBytes: 10_000,
                                      requiredBytes: 1_000),
            capability: ImportCapabilityFacts(writeToolsAvailable: true, readbackAvailable: true),
            expectedSHA256: intent.source.contentSHA256, now: now))
    }


    /// Builds a stack whose run ID and intent run IDs share one ledger run.
    static func stack(_ approval: Approval = .canonical) throws -> Stack {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(database)
        let ledger = ImportLedger(database: database)
        let authorization = try authorization(approval)
        let runID = UUID()
        try ledger.startRun(ImportRunRecord(
            id: runID, scopeID: UUID(), manifestID: UUID(), manifestRevision: 1,
            profileID: "project-archive", profileVersion: "1.0.0", schemaVersion: "1.0",
            authorizationDigest: authorization.digest, startedAt: now))

        let transport = FakeImportTransport()
        let fixed = now
        let writer = ImportSingleWriter(ledger: ledger, owner: "m05-qa", clock: { fixed })
        // Setup creates the two approved groups; the run itself is authorized
        // only for its own group. Both share the approval's journal identity,
        // so the group budget is the single two-group allowance.
        let setupScope = scope(prefix: [groupRoot])
        let runtimeScope = scope(prefix: groupPath(approval))
        let runtime = ImportRuntime(ledger: ledger, writer: writer, read: transport,
                                    clock: { fixed }) { runtimeAuthorization in
            let guardAuthorization = ImportWriteAuthorization(
                scope: runtimeAuthorization.scope, journal: ledger,
                identity: runtimeAuthorization.digest, clock: { fixed })
            let surface = GuardedImportWriteTransport(
                base: transport, authorization: guardAuthorization,
                sourcePath: { binding in
                    ImportWriteScope.canonical("\(sourceRoot)/\(binding.relativePath)")
                })
            return ImportWriteSession(surface: surface, authorization: guardAuthorization,
                                      close: {})
        }
        let groupGuard = GuardedImportWriteTransport(
            base: transport,
            authorization: ImportWriteAuthorization(scope: setupScope, journal: ledger,
                                                    identity: authorization.digest,
                                                    clock: { fixed }),
            sourcePath: { binding in
                ImportWriteScope.canonical("\(sourceRoot)/\(binding.relativePath)")
            })

        var intents: [ImportIntent] = []
        var clearances: [ImportPreflightClearance] = []
        let preflight = preflightAuthorization(approval)
        for (index, file) in files.enumerated() {
            let intent = try intent(file, runID: runID, approval: approval,
                                    authorizationDigest: preflight.digest,
                                    metadata: ["projectname": "M05-\(index + 1)"])
            intents.append(intent)
            clearances.append(try clearance(intent, authorization: preflight))
        }
        return Stack(database: database, ledger: ledger, transport: transport, runtime: runtime,
                     runID: runID, authorization: authorization, scope: runtimeScope,
                     groupGuard: groupGuard, intents: intents, clearances: clearances,
                     preflight: preflight)
    }

    static func requests(_ stack: Stack) -> [ImportRuntimeRequest] {
        zip(stack.intents, stack.clearances).map {
            ImportRuntimeRequest(intent: $0.0, clearance: $0.1)
        }
    }

    /// Creates the two approved groups. This happens outside the run, as the
    /// preflight does, but through the same journaled guard.
    static func createGroups(_ stack: Stack) async throws {
        let target = stack.authorization.target.groupPath
        _ = try await stack.groupGuard.createGroup(database: databaseID, path: [groupRoot])
        _ = try await stack.groupGuard.createGroup(database: databaseID, path: target)
    }

    // MARK: - Report

    struct Probe: Sendable, Equatable, Codable {
        let keyDigest: String
        let phase: String
        let reason: String?
    }

    struct Report: Sendable, Equatable, Codable {
        let authorizationDigest: String
        let limits: ImportWriteBudgetLimits
        let budget: ImportWriteBudgetUsage
        let refusals: [String: Int]
        let probes: [Probe]
        let createCalls: Int
        let metadataCalls: Int
        let createGroupCalls: Int
        let recoveryOutcomes: [String]

        func json() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
    }

    static func report(_ stack: Stack,
                       results: [ImportExecutionResult],
                       recovery: [String] = []) async throws -> Report {
        var probes: [Probe] = []
        for record in try stack.ledger.operations(runID: stack.runID) {
            probes.append(Probe(keyDigest: record.keyDigest, phase: record.phase.rawValue,
                                reason: nil))
        }
        for result in results where result.reason != nil {
            probes.append(Probe(keyDigest: "result", phase: result.phase.rawValue,
                                reason: result.reason?.rawValue))
        }
        // The journal is the single source of truth: the group guard's local
        // counters were loaded before the runtime spent its imports/metadata.
        let budget = try stack.ledger.budgetUsage(identity: stack.authorization.digest) ?? .zero
        let refusalCounts = await stack.groupGuard.refusalCounts
        return Report(
            authorizationDigest: stack.authorization.digest,
            limits: stack.scope.limits,
            budget: budget,
            refusals: refusalCounts.mapKeys { $0.rawValue },
            probes: probes,
            createCalls: await stack.transport.createCalls,
            metadataCalls: await stack.transport.metadataCalls,
            createGroupCalls: await stack.transport.createGroupCalls,
            recoveryOutcomes: recovery)
    }

    /// Simulates the residue a process would leave if it died after recording
    /// the UUID but before the readback: the ledger row is at `record_observed`
    /// and the record exists. This is state setup, not an injected network fault.
    static func seedCrashResidue(_ stack: Stack, file: SyntheticFile,
                                 uuid: String) async throws -> ImportIntent {
        let intent = try intent(file, runID: stack.runID, approval: .canonical,
                                authorizationDigest: stack.preflight.digest,
                                metadata: ["projectname": "M05-CRASH"])
        let operation = ImportOperationRecord(
            runID: stack.runID, key: intent.key,
            targetDatabase: databaseID, targetGroupPath: intent.groupPath,
            intendedMetadataDigest: String(repeating: "0", count: 64),
            intendedMetadataJSON: "{}", sourceSHA256: intent.source.contentSHA256,
            authorizationDigest: intent.authorizationDigest, createdAt: now)
        _ = try stack.ledger.recordIntent(operation)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: now)
        try stack.ledger.observeActualUUID(uuid, keyDigest: intent.key.digest, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .recordObserved, at: now)
        // The crashed process left the record behind as well as the intent.
        await stack.transport.seed(.init(uuid: uuid, database: databaseID,
                                         parentPath: intent.groupPath,
                                         metadata: [:], sha256: file.sha256,
                                         associationBasis: intent.associationBasis))
        return intent
    }
}

extension Dictionary where Key: RawRepresentable, Key.RawValue == String {
    fileprivate func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        reduce(into: [:]) { $0[transform($1.key)] = $1.value }
    }
}
