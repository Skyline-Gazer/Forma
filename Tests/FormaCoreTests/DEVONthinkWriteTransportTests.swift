import Foundation
import Testing

@testable import FormaCore

/// The adapter is the only place that names a write tool. These tests pin the
/// exact arguments it sends, because "the call went through" is not evidence
/// that it went to the authorized database, group and file.
@Suite("DEVONthink MCP write adapter")
struct DEVONthinkWriteTransportTests {
    private static let database = "AAAAAAAA-0000-4000-8000-000000000001"
    private static let recordUUID = "BBBBBBBB-0000-4000-8000-000000000002"
    private static let groupUUID = "CCCCCCCC-0000-4000-8000-000000000003"

    private static let prelude = #"""
    next() {
        IFS= read -r line || exit 1
        id=${line#*\"id\":}
        id=${id%%,*}
    }
    expect() {
        case "$line" in *"$1"*) ;; *) exit 2 ;; esac
    }
    respond() {
        printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"
    }
    ready() {
        next
        expect '"method":"initialize"'
        respond "$id" '{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0"}}'
        next
        expect '"method":"notifications/initialized"'
    }
    keep_open() {
        while IFS= read -r extra; do exit 3; done
    }
    """#

    private static func fake(_ script: String) throws -> MCPConfiguration {
        MCPConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                         arguments: ["-c", prelude + "\n" + script], timeout: .seconds(15))
    }

    private static func source() -> ImportSourceBinding {
        ImportSourceBinding(
            sourceID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
            relativePath: "forma-b1-probe-01.md",
            snapshotFingerprint: String(repeating: "a", count: 64),
            contentSHA256: String(repeating: "b", count: 64),
            byteCount: 47, readSessionID: "session-1")
    }

    @Test func importFileSendsAuthorizedDatabaseGroupAndImportMode() async throws {
        let transport = DEVONthinkMCPWriteTransport(
            configuration: try Self.fake(#"""
            ready
            next
            expect '"name":"import_file"'
            expect '"path":"/tmp/source-root/forma-b1-probe-01.md"'
            expect '"destination":"Forma_I1B2/run-1"'
            expect '"database_uuid":"AAAAAAAA-0000-4000-8000-000000000001"'
            expect '"mode":"import"'
            case "$line" in *'"mode":"index"'*) exit 4;; esac
            respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"BBBBBBBB-0000-4000-8000-000000000002\"}"}]}'
            keep_open
            """#),
            sourceRoot: URL(fileURLWithPath: "/tmp/source-root"))
        let uuid = try await transport.create(ImportCreateRequest(
            database: Self.database, groupPath: ["Forma_I1B2", "run-1"], associationBasis: nil,
            metadata: ["projectname": "FORMA-SYNTHETIC"], source: Self.source()))
        #expect(uuid == Self.recordUUID)
        #expect(await transport.transcriptLines() == ["import_file"])
        await transport.close()
    }

    @Test func createGroupSendsLocationAndDatabase() async throws {
        let transport = DEVONthinkMCPWriteTransport(
            configuration: try Self.fake(#"""
            ready
            next
            expect '"name":"create_group_path"'
            expect '"location":"Forma_I1B2/run-1"'
            expect '"database_uuid":"AAAAAAAA-0000-4000-8000-000000000001"'
            respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"CCCCCCCC-0000-4000-8000-000000000003\"}"}]}'
            keep_open
            """#),
            sourceRoot: URL(fileURLWithPath: "/tmp/source-root"))
        let uuid = try await transport.createGroup(database: Self.database,
                                                   path: ["Forma_I1B2", "run-1"])
        #expect(uuid == Self.groupUUID)
        await transport.close()
    }

    @Test func metadataUsesMergeAndSendsTheWholeBody() async throws {
        let transport = DEVONthinkMCPWriteTransport(
            configuration: try Self.fake(#"""
            ready
            next
            expect '"name":"set_record_custom_metadata"'
            expect '"uuid":"BBBBBBBB-0000-4000-8000-000000000002"'
            expect '"mode":"merge"'
            expect '"projectname":"FORMA-SYNTHETIC"'
            expect '"issuer":null'
            case "$line" in *'"mode":"replace"'*) exit 4;; esac
            respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"BBBBBBBB-0000-4000-8000-000000000002\"}"}]}'
            keep_open
            """#),
            sourceRoot: URL(fileURLWithPath: "/tmp/source-root"))
        try await transport.writeMetadata(ImportMetadataRequest(
            uuid: Self.recordUUID,
            metadata: ["projectname": "FORMA-SYNTHETIC", "issuer": nil],
            source: Self.source()))
        await transport.close()
    }

    @Test func ambiguousAnswerIsNotARecordIdentity() async throws {
        let transport = DEVONthinkMCPWriteTransport(
            configuration: try Self.fake(#"""
            ready
            next
            expect '"name":"import_file"'
            respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"BBBBBBBB-0000-4000-8000-000000000002\",\"duplicate\":\"DDDDDDDD-0000-4000-8000-000000000004\"}"}]}'
            keep_open
            """#),
            sourceRoot: URL(fileURLWithPath: "/tmp/source-root"))
        let ambiguous = try await transport.create(ImportCreateRequest(
            database: Self.database, groupPath: ["Forma_I1B2", "run-1"], associationBasis: nil,
            metadata: [:], source: Self.source()))
        #expect(ambiguous.isEmpty) // two candidates: "which record?" is unanswered
        await transport.close()
    }

    @Test func serverErrorIsNotSuccess() async throws {
        let transport = DEVONthinkMCPWriteTransport(
            configuration: try Self.fake(#"""
            ready
            next
            expect '"name":"set_record_custom_metadata"'
            respond "$id" '{"isError":true,"content":[{"type":"text","text":"Record not found: nope"}]}'
            keep_open
            """#),
            sourceRoot: URL(fileURLWithPath: "/tmp/source-root"))
        await #expect(throws: FormaError.refused) {
            try await transport.writeMetadata(ImportMetadataRequest(
                uuid: Self.recordUUID, metadata: ["projectname": "x"], source: Self.source()))
        }
        await transport.close()
    }

    @Test func contentPathIsReadOnlyAndBindsTheRecordIdentity() async throws {
        let client = DEVONthinkReadOnlyClient(configuration: try Self.fake(#"""
        ready
        next
        expect '"method":"tools/list"'
        respond "$id" '{"tools":[{"name":"get_imported_record_path","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"},"database_uuid":{"type":"string"}}}}]}'
        next
        expect '"name":"get_imported_record_path"'
        respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"BBBBBBBB-0000-4000-8000-000000000002\",\"filename\":\"forma-b1-probe-01.md\",\"path\":\"\\/tmp\\/pkg\\/forma-b1-probe-01.md\",\"indexed\":false}"}]}'
        keep_open
        """#))
        _ = try await client.discover()
        let scope = DEVONthinkReadScope(
            databaseID: UUID(uuidString: Self.database)!,
            recordIDs: [UUID(uuidString: Self.recordUUID)!])
        let path = try await client.contentPath(of: UUID(uuidString: Self.recordUUID)!, in: scope)
        #expect(path == "/tmp/pkg/forma-b1-probe-01.md")
        await client.close()
    }
}
