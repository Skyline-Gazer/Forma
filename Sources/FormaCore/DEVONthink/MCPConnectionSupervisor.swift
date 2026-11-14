import Foundation

/// One JSON-RPC connection to the DEVONthink MCP server.
///
/// Internal on purpose: it speaks `MCPValue`, and nothing above `FormaCore`
/// should be able to send an arbitrary MCP call. The two clients are the only
/// callers, and each owns its own channel.
protocol MCPConnection: AnyObject, Sendable {
    func request(_ method: String, parameters: [String: MCPValue]) async throws -> MCPValue
    /// Sends the `notifications/initialized` notification the server requires
    /// after the handshake. It has no reply, so it is not a `request`.
    func sendInitialized() async throws
    func checkOpen() async throws
    func close() async
}

extension MCPStdio: MCPConnection {
    func sendInitialized() async throws { try initialized() }
}

/// Owns the lifetime of the MCP children: how many may exist, when a dead one is
/// replaced, and when replacement stops.
///
/// The rule that shapes this type is that **rebuilding a connection is not
/// retrying a request**. The supervisor never re-sends anything; it only decides
/// which connection the *next* call uses. A request whose outcome is unknown is
/// the caller's problem, and both clients answer it the same way: mark the
/// operation `verify_required` and read the target back.
///
/// Health checking is deliberately limited to what the live server was observed
/// to support (I1-B1): process liveness plus the MCP handshake. It does not send
/// `ping`, because a client must not assume a capability nobody verified.
actor MCPConnectionSupervisor {
    enum Channel: String, CaseIterable, Sendable {
        case read
        case write
    }

    struct Policy: Sendable, Equatable {
        /// Consecutive failures after which replacement stops. `2` means: the
        /// first failure earns one rebuild, the second one earns another, the
        /// third marks the channel exhausted.
        var maximumFailures: Int
        var initialBackoff: Duration
        var maximumBackoff: Duration

        init(maximumFailures: Int = 3, initialBackoff: Duration = .milliseconds(200),
             maximumBackoff: Duration = .seconds(5)) {
            self.maximumFailures = maximumFailures
            self.initialBackoff = initialBackoff
            self.maximumBackoff = maximumBackoff
        }
    }

    struct ChannelState: Sendable, Equatable {
        let channel: Channel
        let generation: Int
        let connected: Bool
        let consecutiveFailures: Int
        let exhausted: Bool
        let lastErrorCode: String?
    }

    private struct Slot {
        var connection: (any MCPConnection)?
        var generation = 0
        var failures = 0
        var exhausted = false
        var lastError: FormaError?
    }

    private let policy: Policy
    private let factory: @Sendable () -> any MCPConnection
    private let sleep: @Sendable (Duration) async throws -> Void
    private var slots: [Channel: Slot] = [:]

    init(policy: Policy = Policy(),
         factory: @escaping @Sendable () -> any MCPConnection,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.policy = policy
        self.factory = factory
        self.sleep = sleep
    }

    /// Returns a connection the caller may use for its next request.
    ///
    /// A live connection is re-checked first; a dead one is closed, counted, and
    /// replaced after a bounded backoff. Once the failure budget is spent the
    /// channel stays exhausted until somebody resets it — a retry loop must not
    /// be able to spawn children forever.
    func connection(for channel: Channel) async throws -> any MCPConnection {
        var slot = slots[channel] ?? Slot()
        if slot.exhausted { throw slot.lastError ?? .unavailable }

        if let existing = slot.connection {
            do {
                try await existing.checkOpen()
                return existing
            } catch let error as FormaError {
                await existing.close()
                slot.connection = nil
                slot.failures += 1
                slot.lastError = error
                slots[channel] = slot
            } catch {
                await existing.close()
                slot.connection = nil
                slot.failures += 1
                slot.lastError = .disconnected
                slots[channel] = slot
            }
            guard slot.failures < policy.maximumFailures else {
                slot.exhausted = true
                slots[channel] = slot
                throw slot.lastError ?? .unavailable
            }
            // Wait before replacing, so a server that dies on start cannot be
            // restarted in a tight loop.
            guard !Task.isCancelled else { throw FormaError.cancelled }
            do { try await sleep(backoff(for: slot.failures)) }
            catch { throw FormaError.cancelled }
        } else if slot.failures > 0 {
            guard slot.failures < policy.maximumFailures else {
                slot.exhausted = true
                slots[channel] = slot
                throw slot.lastError ?? .unavailable
            }
            guard !Task.isCancelled else { throw FormaError.cancelled }
            do { try await sleep(backoff(for: slot.failures)) }
            catch { throw FormaError.cancelled }
        }

        guard !Task.isCancelled else { throw FormaError.cancelled }
        slot.generation += 1
        let connection = factory()
        slot.connection = connection
        slot.lastError = nil
        slots[channel] = slot
        return connection
    }

    /// Records that a call on this channel ended in an unknown or terminal state.
    ///
    /// The connection is closed so no later call can reuse a pipe whose peer is
    /// gone; the failure counts against the budget even when the caller keeps the
    /// channel for a different operation.
    func invalidate(_ channel: Channel, because error: FormaError) async {
        var slot = slots[channel] ?? Slot()
        if let connection = slot.connection { await connection.close() }
        slot.connection = nil
        slot.failures += 1
        slot.lastError = error
        if slot.failures >= policy.maximumFailures { slot.exhausted = true }
        slots[channel] = slot
    }

    /// Clears the failure budget. Called by an explicit user action, never from
    /// an automatic retry path.
    func reset(_ channel: Channel) {
        var slot = slots[channel] ?? Slot()
        slot.failures = 0
        slot.exhausted = false
        slot.lastError = nil
        slots[channel] = slot
    }

    func close() async {
        for channel in Channel.allCases {
            guard var slot = slots[channel] else { continue }
            if let connection = slot.connection { await connection.close() }
            slot.connection = nil
            slots[channel] = slot
        }
    }

    func states() -> [ChannelState] {
        Channel.allCases.map { channel in
            let slot = slots[channel] ?? Slot()
            return ChannelState(
                channel: channel, generation: slot.generation,
                connected: slot.connection != nil, consecutiveFailures: slot.failures,
                exhausted: slot.exhausted, lastErrorCode: slot.lastError?.code)
        }
    }

    /// Total live children. The dictionary has exactly two channels and each
    /// slot holds at most one connection, so the cap is structural; this is the
    /// observable form of that statement.
    func liveConnectionCount() -> Int {
        Channel.allCases.reduce(into: 0) { count, channel in
            if slots[channel]?.connection != nil { count += 1 }
        }
    }

    private func backoff(for failures: Int) -> Duration {
        var delay = policy.initialBackoff
        for _ in 1..<max(failures, 1) {
            delay = min(delay * 2, policy.maximumBackoff)
        }
        return min(delay, policy.maximumBackoff)
    }
}
