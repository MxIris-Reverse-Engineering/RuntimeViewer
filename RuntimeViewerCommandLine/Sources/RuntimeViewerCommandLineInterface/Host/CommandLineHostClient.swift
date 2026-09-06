import Darwin
import Foundation
import FoundationToolbox

/// The client side of the socket: finds or starts a host, shakes hands, and
/// exchanges commands for results.
///
/// Starting a host: when nothing answers on the socket, the client takes
/// `host.lock`, tries once more (another client may have just started one),
/// and only then launches a host and polls the socket until it answers.
@Loggable
public actor CommandLineHostClient {
    public typealias ProgressHandler = @Sendable (CommandProgress) async -> Void

    public struct Configuration: Sendable {
        public var paths: CommandLineHostPaths
        /// Start a host when none is running.
        public var allowsSpawning: Bool
        /// Idle timeout handed to a host this client starts, in seconds.
        public var spawnIdleTimeout: TimeInterval
        /// How long to wait for a started host to answer.
        public var startupTimeout: TimeInterval
        /// How long to wait for `host.lock`.
        public var lockTimeout: TimeInterval

        public init(paths: CommandLineHostPaths, allowsSpawning: Bool = true, spawnIdleTimeout: TimeInterval = 600, startupTimeout: TimeInterval = 10, lockTimeout: TimeInterval = 15) {
            self.paths = paths
            self.allowsSpawning = allowsSpawning
            self.spawnIdleTimeout = spawnIdleTimeout
            self.startupTimeout = startupTimeout
            self.lockTimeout = lockTimeout
        }
    }

    public enum ClientError: Error, Equatable, CustomStringConvertible {
        /// Nothing answers and the client may not, or cannot, start a host.
        case hostUnreachable(detail: String)
        /// A host was started but never answered.
        case hostDidNotStart(detail: String)
        /// The connection dropped before the command was answered.
        case connectionLost
        case unsupportedProtocolVersion(hostVersion: Int, hostKind: HostKind)
        case notConnected

        public var description: String {
            switch self {
            case .hostUnreachable(let detail):
                return "No CLI host is reachable: \(detail)"
            case .hostDidNotStart(let detail):
                return "The CLI host did not start: \(detail)"
            case .connectionLost:
                return "The connection to the CLI host was lost."
            case .unsupportedProtocolVersion(let hostVersion, let hostKind):
                switch hostKind {
                case .application:
                    return "The running RuntimeViewer app speaks protocol \(hostVersion), this tool speaks \(CommandLineProtocol.version). Update the app or the tool so they match."
                case .standalone:
                    return "The running CLI host speaks protocol \(hostVersion), this tool speaks \(CommandLineProtocol.version). Run `host restart`."
                }
            case .notConnected:
                return "Not connected to a CLI host."
            }
        }

        /// Exit code 69 (`EX_UNAVAILABLE`) territory.
        public var isUnavailability: Bool {
            switch self {
            case .hostUnreachable, .hostDidNotStart: return true
            case .connectionLost, .unsupportedProtocolVersion, .notConnected: return false
            }
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<CommandResult, any Error>
        let onProgress: ProgressHandler?
    }

    private let configuration: Configuration
    private let launcher: (any HostLaunching)?
    private var connection: SocketConnection?
    private var receiveTask: Task<Void, Never>?
    private var pendingRequests: [UUID: PendingRequest] = [:]
    private var welcomeContinuation: CheckedContinuation<Welcome, any Error>?
    private var hasReplacedOutdatedHost = false

    public private(set) var welcome: Welcome?

    public init(configuration: Configuration, launcher: (any HostLaunching)?) {
        self.configuration = configuration
        self.launcher = launcher
    }

    public var isConnected: Bool { connection != nil && welcome != nil }

    // MARK: - Connecting

    /// Connects (starting a host if allowed) and returns the host's greeting.
    @discardableResult
    public func connect() async throws -> Welcome {
        if let welcome, connection != nil {
            return welcome
        }
        let fileDescriptor = try await establishSocket()
        let connection = SocketConnection(fileDescriptor: fileDescriptor)
        self.connection = connection
        startReceiving(connection)

        let welcome: Welcome
        do {
            try await connection.send(WireCoding.encodeFrame(ClientMessage.hello(Hello())))
            welcome = try await withCheckedThrowingContinuation { continuation in
                welcomeContinuation = continuation
            }
        } catch {
            disconnect()
            throw ClientError.connectionLost
        }

        guard welcome.protocolVersion == CommandLineProtocol.version else {
            if welcome.hostKind == .standalone, configuration.allowsSpawning, launcher != nil, !hasReplacedOutdatedHost {
                hasReplacedOutdatedHost = true
                await replaceOutdatedHost(welcome)
                return try await connect()
            }
            disconnect()
            throw ClientError.unsupportedProtocolVersion(hostVersion: welcome.protocolVersion, hostKind: welcome.hostKind)
        }
        self.welcome = welcome
        return welcome
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.close()
        connection = nil
        welcome = nil
        failEverything(with: ClientError.connectionLost)
    }

    private func establishSocket() async throws -> Int32 {
        let socketPath = configuration.paths.socketURL.path
        do {
            try UnixDomainSocket.validatePath(socketPath)
        } catch {
            throw ClientError.hostUnreachable(detail: String(describing: error))
        }
        switch Self.tryConnect(to: socketPath) {
        case .success(let fileDescriptor):
            return fileDescriptor
        case .failure(let error) where !error.indicatesAbsentHost:
            throw ClientError.hostUnreachable(detail: String(describing: error))
        case .failure:
            break
        }

        guard configuration.allowsSpawning else {
            throw ClientError.hostUnreachable(detail: "nothing is listening at \(socketPath) and starting a host is disabled.")
        }
        guard let launcher else {
            throw ClientError.hostUnreachable(detail: "nothing is listening at \(socketPath) and this process cannot start a host.")
        }

        try configuration.paths.prepareDirectory()
        let lock: FileLock?
        do {
            lock = try await FileLock.acquire(at: configuration.paths.clientLockURL, timeout: configuration.lockTimeout)
        } catch {
            throw ClientError.hostUnreachable(detail: String(describing: error))
        }
        guard let lock else {
            throw ClientError.hostUnreachable(detail: "another client has held \(configuration.paths.clientLockURL.lastPathComponent) for more than \(Int(configuration.lockTimeout)) s.")
        }
        defer { lock.release() }

        // Another client may have started a host while this one waited for the lock.
        if case .success(let fileDescriptor) = Self.tryConnect(to: socketPath) {
            return fileDescriptor
        }

        do {
            try launcher.launchHost(paths: configuration.paths, idleTimeout: configuration.spawnIdleTimeout)
        } catch {
            throw ClientError.hostDidNotStart(detail: String(describing: error))
        }
        #log(.info, "Started a CLI host for \(socketPath, privacy: .public)")

        let deadline = ContinuousClock.now + .seconds(configuration.startupTimeout)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if case .success(let fileDescriptor) = Self.tryConnect(to: socketPath) {
                return fileDescriptor
            }
        }
        throw ClientError.hostDidNotStart(detail: "it did not answer within \(Int(configuration.startupTimeout)) s; see \(configuration.paths.logURL.path).")
    }

    private static func tryConnect(to socketPath: String) -> Result<Int32, UnixDomainSocket.SystemError> {
        do {
            return .success(try UnixDomainSocket.connect(to: socketPath))
        } catch let error as UnixDomainSocket.SystemError {
            return .failure(error)
        } catch {
            return .failure(UnixDomainSocket.SystemError("connect", code: EINVAL))
        }
    }

    /// Asks an outdated standalone host to leave and waits until its socket is
    /// gone, falling back to `SIGTERM` on the recorded process.
    private func replaceOutdatedHost(_ welcome: Welcome) async {
        #log(.info, "Replacing an outdated CLI host (protocol \(welcome.protocolVersion, privacy: .public))")
        _ = try? await Timeouts.withTimeout(seconds: 3) {
            try await self.send(.shutdownHost(.userRequest))
        }
        disconnect()
        let socketPath = configuration.paths.socketURL.path
        for _ in 0 ..< 50 where UnixDomainSocket.isHostListening(at: socketPath) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if UnixDomainSocket.isHostListening(at: socketPath) {
            kill(welcome.processIdentifier, SIGTERM)
            for _ in 0 ..< 20 where UnixDomainSocket.isHostListening(at: socketPath) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Sending

    /// Sends a command and waits for its result. Cancelling the calling task
    /// asks the host to cancel the command and returns `CommandFailure.cancelled`.
    public func send(_ command: Command, onProgress: ProgressHandler? = nil) async throws -> CommandResult {
        guard let connection else {
            throw ClientError.notConnected
        }
        let requestIdentifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, any Error>) in
                pendingRequests[requestIdentifier] = PendingRequest(continuation: continuation, onProgress: onProgress)
                Task {
                    do {
                        try await connection.send(WireCoding.encodeFrame(ClientMessage.command(requestIdentifier: requestIdentifier, command: command)))
                    } catch {
                        self.fail(requestIdentifier, with: ClientError.connectionLost)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(requestIdentifier) }
        }
    }

    private func cancel(_ requestIdentifier: UUID) {
        guard let pending = pendingRequests.removeValue(forKey: requestIdentifier) else { return }
        if let connection {
            Task { try? await connection.send(WireCoding.encodeFrame(ClientMessage.cancel(requestIdentifier: requestIdentifier))) }
        }
        pending.continuation.resume(throwing: CommandFailure(code: .cancelled, message: "The command was cancelled."))
    }

    private func fail(_ requestIdentifier: UUID, with error: any Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestIdentifier) else { return }
        pending.continuation.resume(throwing: error)
    }

    private func failEverything(with error: any Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.continuation.resume(throwing: error)
        }
        if let welcomeContinuation {
            self.welcomeContinuation = nil
            welcomeContinuation.resume(throwing: error)
        }
    }

    // MARK: - Receiving

    private func startReceiving(_ connection: SocketConnection) {
        receiveTask = Task { [weak self] in
            do {
                for try await payload in connection.incomingPayloads {
                    guard let self else { return }
                    let message = try WireCoding.decode(HostMessage.self, from: payload)
                    await self.handle(message)
                }
            } catch {
                #log(.debug, "Receive loop ended: \(error.localizedDescription, privacy: .public)")
            }
            await self?.connectionDidEnd(connection)
        }
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .welcome(let welcome):
            if let welcomeContinuation {
                self.welcomeContinuation = nil
                welcomeContinuation.resume(returning: welcome)
            }
        case .progress(let requestIdentifier, let progress):
            if let onProgress = pendingRequests[requestIdentifier]?.onProgress {
                Task { await onProgress(progress) }
            }
        case .completed(let requestIdentifier, let result):
            pendingRequests.removeValue(forKey: requestIdentifier)?.continuation.resume(returning: result)
        case .failed(let requestIdentifier, let failure):
            pendingRequests.removeValue(forKey: requestIdentifier)?.continuation.resume(throwing: failure)
        }
    }

    private func connectionDidEnd(_ endedConnection: SocketConnection) {
        guard connection === endedConnection else { return }
        connection = nil
        welcome = nil
        failEverything(with: ClientError.connectionLost)
    }
}

/// Races an operation against a deadline.
public enum Timeouts {
    public struct TimedOut: Error, Equatable {
        public let seconds: TimeInterval
    }

    public static func withTimeout<Value: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut(seconds: seconds)
            }
            guard let value = try await group.next() else {
                throw TimedOut(seconds: seconds)
            }
            group.cancelAll()
            return value
        }
    }
}
