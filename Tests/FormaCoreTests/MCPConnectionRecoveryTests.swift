import CryptoKit
import Foundation
import Testing
@testable import FormaCore

/// The connection layer against a real `/bin/sh` peer.
///
/// `MCPConnectionSupervisorTests` covers the policy with fake connections. These
/// tests prove the two clients actually reach the policy: a peer that exits is
/// replaced for the next call, and a rebuilt connection re-checks the write
/// tools before sending anything.
private let databaseID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let rootTwo = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!

private let prelude = #"""
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
handshake() {
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

private func config(_ script: String, extra: [String] = []) -> MCPConfiguration {
    MCPConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                     arguments: ["-c", prelude + "\n" + script, "forma-fixture"] + extra,
                     timeout: .seconds(15))
}

private func canonicalDigest(_ json: String) throws -> String {
    let value = try JSONDecoder().decode(MCPValue.self, from: Data(json.utf8))
    return SHA256.hash(data: try value.canonicalData()).map { String(format: "%02x", $0) }.joined()
}

@Test func readClientReachesAFreshPeerAfterTheOldOneExits() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let client = DEVONthinkReadOnlyClient(configuration: config(#"""
    handshake
    next
    expect '"method":"tools/list"'
    respond "$id" '{"tools":[{"name":"get_databases","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"}}}}]}'
    next
    expect '"name":"get_databases"'
    if [ -e "$1" ]; then
        respond "$id" '{"content":[{"type":"text","text":"[{\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"rootUUID\":\"00000000-0000-4000-8000-0000000000a2\",\"name\":\"Sandbox\"}]"}],"isError":false}'
        keep_open
    else
        # First process: no answer, then gone. The call must fail, not hang.
        : > "$1"
        exit 0
    fi
    """#, extra: [marker.path]))
    let scope = DEVONthinkReadScope(databaseID: databaseID)

    _ = try await client.discover()
    await #expect(throws: FormaError.self) { try await client.database(in: scope) }

    // The failed call retired the connection, so the next negotiation has to
    // reach the second process rather than reuse a pipe whose peer is gone.
    _ = try await client.discover()
    let second = try await client.database(in: scope)
    #expect(second.rootGroupID == rootTwo)
    await client.close()
}

@Test func writeTransportVerifiesTheToolContractOnEveryConnection() async throws {
    let schema = #"{"type":"object","properties":{"path":{"type":"string"}}}"#
    let contract = DEVONthinkWriteToolContract(digests: [
        "import_file": try canonicalDigest(schema),
    ])
    let transport = DEVONthinkMCPWriteTransport(
        configuration: config(#"""
        handshake
        next
        expect '"method":"tools/list"'
        respond "$id" '{"tools":[{"name":"import_file","inputSchema":\#(schema)}]}'
        next
        expect '"name":"import_file"'
        respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"BBBBBBBB-0000-4000-8000-000000000002\"}"}]}'
        keep_open
        """#),
        sourceRoot: URL(fileURLWithPath: "/tmp/source-root"), contract: contract)

    let request = ImportCreateRequest(
        database: "AAAAAAAA-0000-4000-8000-000000000001", groupPath: ["Forma_I1B2", "run-1"],
        associationBasis: nil, metadata: ["projectname": "FORMA-SYNTHETIC"],
        source: ImportSourceBinding(
            sourceID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
            relativePath: "forma-b1-probe-01.md",
            snapshotFingerprint: String(repeating: "a", count: 64),
            contentSHA256: String(repeating: "b", count: 64),
            byteCount: 47, readSessionID: "session-1"))

    #expect(try await transport.create(request) == "BBBBBBBB-0000-4000-8000-000000000002")
    // A second connection is verified again before it is used.
    await transport.close()
    #expect(try await transport.create(request) == "BBBBBBBB-0000-4000-8000-000000000002")
    #expect(await transport.transcriptLines() == ["import_file", "import_file"])
    await transport.close()
}

@Test func writeTransportRefusesADriftedToolContract() async throws {
    let original = #"{"type":"object","properties":{"path":{"type":"string"}}}"#
    let drifted = #"{"type":"object","properties":{"file":{"type":"string"}}}"#
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let contract = DEVONthinkWriteToolContract(digests: [
        "import_file": try canonicalDigest(original),
    ])
    let transport = DEVONthinkMCPWriteTransport(
        configuration: config(#"""
        handshake
        next
        expect '"method":"tools/list"'
        if [ -e "$1" ]; then
            respond "$id" '{"tools":[{"name":"import_file","inputSchema":\#(drifted)}]}'
        else
            : > "$1"
            respond "$id" '{"tools":[{"name":"import_file","inputSchema":\#(original)}]}'
        fi
        next
        expect '"name":"import_file"'
        respond "$id" '{"isError":false,"content":[{"type":"text","text":"{\"uuid\":\"BBBBBBBB-0000-4000-8000-000000000002\"}"}]}'
        keep_open
        """#, extra: [marker.path]),
        sourceRoot: URL(fileURLWithPath: "/tmp/source-root"), contract: contract)

    let request = ImportCreateRequest(
        database: "AAAAAAAA-0000-4000-8000-000000000001", groupPath: ["Forma_I1B2", "run-1"],
        associationBasis: nil, metadata: ["projectname": "FORMA-SYNTHETIC"],
        source: ImportSourceBinding(
            sourceID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
            relativePath: "forma-b1-probe-01.md",
            snapshotFingerprint: String(repeating: "a", count: 64),
            contentSHA256: String(repeating: "b", count: 64),
            byteCount: 47, readSessionID: "session-1"))

    _ = try await transport.create(request)
    await transport.close()

    // The rebuilt connection reports a schema this adapter was not reviewed
    // against: nothing is sent through it.
    await #expect(throws: FormaError.incompatible) { try await transport.create(request) }
    #expect(await transport.transcriptLines() == ["import_file"])
    await transport.close()
}

@Test func writeTransportRefusesAContractWhenTheToolIsMissing() async throws {
    let schema = #"{"type":"object","properties":{"path":{"type":"string"}}}"#
    let transport = DEVONthinkMCPWriteTransport(
        configuration: config(#"""
        handshake
        next
        expect '"method":"tools/list"'
        respond "$id" '{"tools":[{"name":"import_file","inputSchema":\#(schema)}]}'
        keep_open
        """#),
        sourceRoot: URL(fileURLWithPath: "/tmp/source-root"),
        contract: DEVONthinkWriteToolContract(digests: [
            "import_file": try canonicalDigest(schema),
            "set_record_custom_metadata": try canonicalDigest(schema),
        ]))

    await #expect(throws: FormaError.incompatible) {
        try await transport.createGroup(database: "AAAAAAAA-0000-4000-8000-000000000001",
                                        path: ["Forma_I1B2", "run-1"])
    }
    #expect(await transport.transcriptLines().isEmpty)
    await transport.close()
}
