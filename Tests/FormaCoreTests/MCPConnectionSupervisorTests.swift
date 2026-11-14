import CryptoKit
import Foundation
import Testing
@testable import FormaCore

/// One scripted MCP peer for the supervisor tests.
///
/// It is a fake *connection*, not a fake process: these tests are about how many
/// children may exist and when one is replaced. The live-process path is covered
/// by `MCPTests`, which spawns a real `/bin/sh` peer.
private actor FakeConnection: MCPConnection {
    let serial: Int
    private(set) var closed = false
    private(set) var calls: [String] = []
    var failure: FormaError?

    init(serial: Int) { self.serial = serial }

    func request(_ method: String, parameters: [String: MCPValue]) async throws -> MCPValue {
        calls.append(method)
        if let failure { throw failure }
        return .object([:])
    }

    func sendInitialized() async throws { calls.append("notifications/initialized") }
    func checkOpen() async throws { if closed { throw FormaError.disconnected } }
    func close() async { closed = true }

    func fail(_ error: FormaError) { failure = error }
    func clearFailure() { failure = nil }
    func recordedCalls() -> [String] { calls }
    func isClosed() -> Bool { closed }
}

/// Counts creations and keeps every connection readable from the test.
private final class ConnectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeConnection] = []

    func make() -> FakeConnection {
        lock.lock()
        defer { lock.unlock() }
        let connection = FakeConnection(serial: made.count)
        made.append(connection)
        return connection
    }

    var all: [FakeConnection] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    var count: Int { all.count }
}

private final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Duration] = []

    func record(_ delay: Duration) {
        lock.lock()
        defer { lock.unlock() }
        delays.append(delay)
    }

    var all: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }
}

private func supervisor(_ log: ConnectionLog, failures: Int = 3,
                        delays: DelayLog? = nil) -> MCPConnectionSupervisor {
    MCPConnectionSupervisor(
        policy: .init(maximumFailures: failures, initialBackoff: .milliseconds(1),
                      maximumBackoff: .milliseconds(8)),
        factory: { log.make() },
        sleep: { delay in delays?.record(delay) })
}

@Suite("MCP connection supervision")
struct MCPConnectionSupervisorTests {
    @Test func aDeadReadConnectionIsReplacedOnceForTheNextRequest() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log)

        let first = try await supervisor.connection(for: .read)
        #expect(log.count == 1)
        await supervisor.invalidate(.read, because: .disconnected)
        let closedFirst = await (first as? FakeConnection)?.isClosed() ?? false
        #expect(closedFirst)

        let second = try await supervisor.connection(for: .read)
        #expect(log.count == 2)
        #expect((second as? FakeConnection)?.serial == 1)
        let states = await supervisor.states()
        let read = try #require(states.first { $0.channel == .read })
        #expect(read.connected)
        #expect(read.consecutiveFailures == 1)
        #expect(read.generation == 2)
        await supervisor.close()
    }

    @Test func anUnknownWriteOutcomeIsNeverReplayed() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log)
        let connection = try #require(try await supervisor.connection(for: .write) as? FakeConnection)

        await connection.fail(.timeout)
        await #expect(throws: FormaError.timeout) { try await connection.request("tools/call") }
        // The pipe is retired because its peer may be gone; the request itself is
        // not repeated anywhere in the supervisor.
        await supervisor.invalidate(.write, because: .timeout)
        #expect(await connection.recordedCalls() == ["tools/call"])

        let replacement = try #require(try await supervisor.connection(for: .write) as? FakeConnection)
        #expect(replacement.serial == 1)
        // Exactly one request on the old connection, none invented on the new one.
        #expect(await replacement.recordedCalls().isEmpty)
        await supervisor.close()
    }

    @Test func aWriteThatLosesItsPeerKeepsTheSameUnknownOutcome() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log)
        let connection = try #require(try await supervisor.connection(for: .write) as? FakeConnection)
        await connection.fail(.disconnected)
        await #expect(throws: FormaError.disconnected) { try await connection.request("tools/call") }
        await supervisor.invalidate(.write, because: .disconnected)

        _ = try await supervisor.connection(for: .write)
        #expect(log.count == 2)
        #expect(await connection.recordedCalls() == ["tools/call"])
        await supervisor.close()
    }

    @Test func aChildThatFailsToStartExhaustsItsBudgetInsteadOfLooping() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log, failures: 2)

        let first = try #require(try await supervisor.connection(for: .read) as? FakeConnection)
        await first.fail(.unavailable)
        await #expect(throws: FormaError.unavailable) { try await first.request("initialize") }
        await supervisor.invalidate(.read, because: .unavailable)

        let second = try #require(try await supervisor.connection(for: .read) as? FakeConnection)
        await second.fail(.unavailable)
        await #expect(throws: FormaError.unavailable) { try await second.request("initialize") }
        await supervisor.invalidate(.read, because: .unavailable)

        // Budget spent: no third child, and the failure is reported, not retried.
        await #expect(throws: FormaError.unavailable) { try await supervisor.connection(for: .read) }
        #expect(log.count == 2)
        let states = await supervisor.states()
        #expect(states.first { $0.channel == .read }?.exhausted == true)
        await supervisor.close()
    }

    @Test func anIncompatiblePeerAlsoCountsAgainstTheBudget() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log, failures: 1)
        _ = try await supervisor.connection(for: .write)
        await supervisor.invalidate(.write, because: .incompatible)

        await #expect(throws: FormaError.incompatible) { try await supervisor.connection(for: .write) }
        #expect(log.count == 1)
        await supervisor.close()
    }

    @Test func cancellationDuringBackoffStopsTheReconnect() async throws {
        let log = ConnectionLog()
        let supervisor = MCPConnectionSupervisor(
            policy: .init(maximumFailures: 3, initialBackoff: .seconds(30),
                          maximumBackoff: .seconds(30)),
            factory: { log.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        _ = try await supervisor.connection(for: .read)
        await supervisor.invalidate(.read, because: .disconnected)

        let task = Task { try await supervisor.connection(for: .read) }
        task.cancel()
        await #expect(throws: FormaError.cancelled) { try await task.value }
        #expect(log.count == 1)
        await supervisor.close()
    }

    @Test func backoffGrowsAndStopsAtTheConfiguredCeiling() async throws {
        let log = ConnectionLog()
        let delays = DelayLog()
        let supervisor = MCPConnectionSupervisor(
            policy: .init(maximumFailures: 4, initialBackoff: .milliseconds(2),
                          maximumBackoff: .milliseconds(4)),
            factory: { log.make() },
            sleep: { delay in delays.record(delay) })

        _ = try await supervisor.connection(for: .read)
        for _ in 0..<3 {
            await supervisor.invalidate(.read, because: .disconnected)
            _ = try await supervisor.connection(for: .read)
        }
        #expect(delays.all == [.milliseconds(2), .milliseconds(4), .milliseconds(4)])
        await supervisor.close()
    }

    @Test func twoChannelsHoldAtMostTwoChildrenAndCloseTogether() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log)
        let read = try #require(try await supervisor.connection(for: .read) as? FakeConnection)
        let write = try #require(try await supervisor.connection(for: .write) as? FakeConnection)

        #expect(log.count == 2)
        #expect(read.serial != write.serial)
        #expect(await supervisor.liveConnectionCount() == 2)

        await supervisor.close()
        #expect(await supervisor.liveConnectionCount() == 0)
        #expect(await read.isClosed())
        #expect(await write.isClosed())
    }

    @Test func anExplicitResetIsTheOnlyWayBackFromExhaustion() async throws {
        let log = ConnectionLog()
        let supervisor = supervisor(log, failures: 1)
        _ = try await supervisor.connection(for: .read)
        await supervisor.invalidate(.read, because: .disconnected)
        await #expect(throws: FormaError.disconnected) { try await supervisor.connection(for: .read) }

        await supervisor.reset(.read)
        _ = try await supervisor.connection(for: .read)
        #expect(log.count == 2)
        await supervisor.close()
    }
}
