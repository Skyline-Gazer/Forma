import Darwin
import Dispatch
import Foundation

enum MCPValue: Codable, Equatable, Sendable {
    case object([String: MCPValue])
    case array([MCPValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .boolean(decoded) }
        else if let decoded = try? value.decode(Int.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([MCPValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: MCPValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var output = encoder.singleValueContainer()
        switch self {
        case .object(let value): try output.encode(value)
        case .array(let value): try output.encode(value)
        case .string(let value): try output.encode(value)
        case .integer(let value): try output.encode(value)
        case .number(let value): try output.encode(value)
        case .boolean(let value): try output.encode(value)
        case .null: try output.encodeNil()
        }
    }

    var object: [String: MCPValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [MCPValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct MCPConfiguration: Sendable {
    let executable: URL
    let arguments: [String]
    var timeout: Duration = .seconds(10)
    var maximumFrameBytes = 2 * 1024 * 1024
    /// How many stderr bytes to keep in memory. The text is never logged or
    /// exported; only a digest and lengths leave this process.
    var stderrLimit = StderrCapture.defaultLimit

    /// When set, every frame written to the child's stdin is journalled here
    /// as one JSON line per `MCPSendEvent` (opened with `O_APPEND`). No file
    /// is created or touched when nil, which is the production default.
    var sendEventLog: URL?

    static let devonThink = Self(
        executable: URL(fileURLWithPath: "/Applications/DEVONthink.app/Contents/Library/LoginItems/DEVONthink MCP.app/Contents/MacOS/DEVONthink MCP"),
        arguments: ["--stdio"]
    )
}

/// One retained fact about a frame this process wrote to the MCP child's
/// stdin. It exists because `docs/M05-PREFLIGHT.md` §14 could not otherwise
/// distinguish, after the fact, "the frame was fully sent and the reply timed
/// out" from "the pipe died before anything left".
///
/// Only protocol metadata is retained: frame identity, byte count, timestamps
/// and the writing pid. A JSON-RPC request frame carries a method name
/// (`tools/call`), never a tool name, and arguments, parameter values, file
/// paths, record contents and response bodies are never included.
public struct MCPSendEvent: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The complete frame (including its newline delimiter) reached the child.
        case written
        /// `write()` returned early or with an error; the frame did not fully leave.
        case partial
    }
    /// Per-transport-instance frame counter, 1-based. Cross-instance ordering
    /// uses `pid` with `uptimeMillis` (monotone within one process), or
    /// `epochMillis` across processes.
    public let sequence: Int
    /// JSON-RPC id for request frames; nil for notifications and for replies
    /// this side sends back to the server.
    public let requestID: Int?
    public let method: String?
    public let outcome: Outcome
    /// Bytes actually written (0 when the write itself failed).
    public let bytes: Int
    public let epochMillis: Int64
    public let uptimeMillis: Int64
    /// Proves which process authored the frame — the same process that owns
    /// the child it was sent to.
    public let pid: Int
}

private final class MCPChild: Sendable {
    let input: FileHandle
    let output: AsyncThrowingStream<Data, any Error>
    let stderr: StderrCapture
    private let process: Process
    private let source: any DispatchSourceRead
    private let stderrSource: any DispatchSourceRead

    init(configuration: MCPConfiguration) throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        let inputFD = input.fileDescriptor
        let outputFD = output.fileDescriptor
        let stderrPipe = Pipe()
        let stderrOutput = stderrPipe.fileHandleForReading
        let stderrFD = stderrOutput.fileDescriptor
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(inputFD, F_SETFL, O_NONBLOCK) == 0,
              fcntl(outputFD, F_SETFL, O_NONBLOCK) == 0,
              fcntl(stderrFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw FormaError.unavailable
        }
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderrPipe
        let capture = StderrCapture(limit: configuration.stderrLimit)
        do { try process.run() } catch { throw FormaError.unavailable }
        // stderr is drained continuously: a full pipe would block the child, and
        // a blocked child looks exactly like a hung server. The bytes stay in a
        // bounded in-memory buffer; only a digest and lengths are ever reported.
        let stderrSource = DispatchSource.makeReadSource(fileDescriptor: stderrFD,
                                                         queue: .global(qos: .utility))
        stderrSource.setEventHandler {
            var bytes = Data(count: 16 * 1024)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(stderrFD, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.count = count
                capture.append(bytes)
            } else if count < 0 && errno != EAGAIN && errno != EINTR {
                stderrSource.cancel()
            }
        }
        stderrSource.setCancelHandler { try? stderrOutput.close() }

        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        let source = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: .global(qos: .utility))
        source.setEventHandler { [weak source] in
            var bytes = Data(count: 16 * 1024)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(outputFD, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.count = count
                if case .dropped = continuation.yield(bytes) {
                    continuation.finish(throwing: FormaError.invalidResponse)
                    source?.cancel()
                }
            } else if count == 0 {
                continuation.finish()
                source?.cancel()
            } else if errno != EAGAIN && errno != EINTR {
                continuation.finish(throwing: FormaError.disconnected)
                source?.cancel()
            }
        }
        source.setCancelHandler {
            try? output.close()
            continuation.finish()
        }
        self.input = input
        self.output = stream
        self.stderr = capture
        self.process = process
        self.source = source
        self.stderrSource = stderrSource
        source.activate()
        stderrSource.activate()
    }

    deinit {
        try? input.close()
        source.cancel()
        stderrSource.cancel()
        let process = process
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

actor MCPStdio {
    private struct Pending {
        let continuation: CheckedContinuation<MCPValue, any Error>
        let deadline: Task<Void, Never>
    }

    private let configuration: MCPConfiguration
    private var child: MCPChild?
    private var reader: Task<Void, Never>?
    private var frame = Data()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var terminalError: FormaError?
    /// The last child's stderr summary, kept after the child is gone so a
    /// post-mortem can still say how much the peer wrote and that it was bounded.
    private var lastStderr: StderrSnapshot = .empty
    /// Opt-in send-boundary journal (see `MCPConfiguration.sendEventLog`).
    private var sendEvents: FileHandle?
    private var sendSequence = 0
    /// Journal appends that failed after the frame itself went out. A field,
    /// not an error: the request's fate must never depend on the evidence log.
    /// QA harnesses assert it stays 0 and treat any nonzero value as "this
    /// run's send boundary is NOT evidence-retained".
    private(set) var sendEventLogFailures = 0

    init(configuration: MCPConfiguration) {
        self.configuration = configuration
    }

    /// A digest and lengths for the child's stderr. Never the text: the raw bytes
    /// stay in the capture buffer on this machine and are not exported.
    func stderrSnapshot() -> StderrSnapshot {
        child?.stderr.snapshot() ?? lastStderr
    }

    func request(_ method: String, parameters: [String: MCPValue] = [:]) async throws -> MCPValue {
        guard !Task.isCancelled else { throw FormaError.cancelled }
        if let terminalError { throw terminalError }
        guard pending.count < 8, nextID < Int.max else { throw FormaError.unavailable }
        if child == nil { try start() }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: FormaError.cancelled)
                    return
                }
                let timeout = configuration.timeout
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.fail(id, with: .timeout)
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                do {
                    try send([
                        "jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(method),
                        "params": .object(parameters)
                    ])
                } catch let error as FormaError {
                    if case .disconnected = error { close(with: error) }
                    else { fail(id, with: error) }
                } catch {
                    fail(id, with: .invalidResponse)
                }
            }
        } onCancel: {
            Task { await self.fail(id, with: .cancelled) }
        }
    }

    func initialized() throws {
        do { try send(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]) }
        catch let error as FormaError { close(with: error); throw error }
    }

    func checkOpen() throws {
        if let terminalError { throw terminalError }
        guard child != nil else { throw FormaError.disconnected }
    }

    func close() { close(with: .disconnected) }

    private func start() throws {
        try openSendEventLog()
        let child = try MCPChild(configuration: configuration)
        self.child = child
        let output = child.output
        reader = Task { [weak self] in
            do {
                for try await bytes in output {
                    guard !Task.isCancelled else { return }
                    await self?.consume(bytes)
                }
                await self?.endOfStream()
            } catch let error as FormaError {
                await self?.close(with: error)
            } catch {
                await self?.close(with: .disconnected)
            }
        }
    }

    private func send(_ object: [String: MCPValue]) throws {
        try checkOpen()
        guard let child else { throw FormaError.disconnected }
        var bytes = try MCPValue.object(object).canonicalData()
        guard bytes.count < 16 * 1024 else { throw FormaError.invalidSource }
        bytes.append(0x0a)
        let written = bytes.withUnsafeBytes {
            var count: Int
            repeat { count = Darwin.write(child.input.fileDescriptor, $0.baseAddress, $0.count) }
            while count < 0 && errno == EINTR
            return count
        }
        // The journal observes the write exactly as it landed: same bytes,
        // same moment, no re-encoding of the request.
        recordSend(object: object, attempted: bytes.count, written: written)
        guard written == bytes.count else { throw FormaError.disconnected }
    }

    /// Opens the opt-in send journal before any child exists, so a run that
    /// asked for boundary evidence cannot silently proceed without it.
    private func openSendEventLog() throws {
        guard let url = configuration.sendEventLog else { return }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw FormaError.unavailable }
        sendEvents = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func recordSend(object: [String: MCPValue], attempted: Int, written: Int) {
        guard sendEvents != nil else { return }
        sendSequence += 1
        let event = MCPSendEvent(
            sequence: sendSequence,
            requestID: object["id"]?.integer,
            method: object["method"]?.string,
            outcome: written == attempted ? .written : .partial,
            bytes: max(written, 0),
            epochMillis: Int64(Date().timeIntervalSince1970 * 1000),
            uptimeMillis: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000),
            pid: Int(getpid()))
        do {
            var data = try JSONEncoder().encode(event)
            data.append(0x0a)
            try sendEvents?.write(contentsOf: data)
        } catch {
            sendEventLogFailures += 1
        }
    }

    private func consume(_ bytes: Data) {
        guard terminalError == nil else { return }
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0a) {
            guard append(bytes[start..<newline]) else { return }
            if frame.last == 0x0d { frame.removeLast() }
            do { try receive(frame) } catch let error as FormaError {
                close(with: error)
                return
            } catch {
                close(with: .invalidResponse)
                return
            }
            frame.removeAll(keepingCapacity: true)
            start = bytes.index(after: newline)
        }
        _ = append(bytes[start...])
    }

    private func append(_ bytes: Data) -> Bool {
        guard bytes.count <= configuration.maximumFrameBytes - frame.count else {
            close(with: .invalidResponse)
            return false
        }
        frame.append(bytes)
        return true
    }

    private func receive(_ data: Data) throws {
        guard let message = try JSONDecoder().decode(MCPValue.self, from: data).object,
              message["jsonrpc"]?.string == "2.0" else { throw FormaError.invalidResponse }
        if let method = message["method"]?.string {
            if let id = message["id"] {
                guard id.string != nil || id.integer != nil else { throw FormaError.invalidResponse }
                if method == "ping" {
                    try send(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
                } else {
                    try send(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                        "code": .integer(-32601), "message": .string("Method not found")
                    ])])
                }
            } else if method == "notifications/tools/list_changed" {
                throw FormaError.incompatible
            }
            return
        }
        guard let id = message["id"]?.integer, id > 0, id <= nextID else { throw FormaError.invalidResponse }
        guard pending[id] != nil else { return } // A timed-out or cancelled reply cannot match a later call.
        switch (message["result"], message["error"]) {
        case (let result?, nil):
            if let call = pending.removeValue(forKey: id) {
                call.deadline.cancel()
                call.continuation.resume(returning: result)
            }
        case (nil, let error?):
            guard let code = error.object?["code"]?.integer,
                  error.object?["message"]?.string != nil else { throw FormaError.invalidResponse }
            fail(id, with: .remoteStatus(code))
        default: throw FormaError.invalidResponse
        }
    }

    private func fail(_ id: Int, with error: FormaError) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.deadline.cancel()
        call.continuation.resume(throwing: error)
    }

    private func endOfStream() {
        close(with: frame.isEmpty ? .disconnected : .invalidResponse)
    }

    private func close(with error: FormaError) {
        guard terminalError == nil else { return }
        terminalError = error
        reader?.cancel()
        reader = nil
        if let child { lastStderr = child.stderr.snapshot() }
        child = nil
        // Release the journal fd; a later reconnect reopens in append mode,
        // so evidence from every connection of one run stays in one file.
        sendEvents = nil
        frame = Data()
        for id in Array(pending.keys) { fail(id, with: error) }
    }
}
