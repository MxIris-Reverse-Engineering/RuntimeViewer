import Darwin
import Foundation
import FoundationToolbox

/// The resident process that owns the engines and answers commands.
///
/// Lifecycle: `start()` takes the instance lock, binds the socket and writes
/// `host.json`; connections are served until the host is idle for
/// `idleTimeout`, a client sends `shutdownHost`, or `stop(reason:)` is called.
/// Idle means no open connection and no command in flight. A shutdown request
/// stops accepting connections, lets in-flight commands finish, then exits.
@Loggable
public actor CommandLineHostServer {
    public struct Configuration: Sendable {
        public var paths: CommandLineHostPaths
        public var kind: HostKind
        /// `nil` never exits on idleness.
        public var idleTimeout: Duration?
        public var version: String

        public init(paths: CommandLineHostPaths, kind: HostKind = .standalone, idleTimeout: Duration? = .seconds(600), version: String = CommandLineToolVersion.current) {
            self.paths = paths
            self.kind = kind
            self.idleTimeout = idleTimeout
            self.version = version
        }
    }

    public enum StopReason: Sendable, Equatable {
        case idle
        case shutdownRequested(ShutdownReason)
        case signal
    }

    public enum StartError: Error, CustomStringConvertible {
        /// Another host holds the instance lock or already answers on the socket.
        case anotherHostIsRunning(recordedProcessIdentifier: Int32?)
        case socket(String)

        public var description: String {
            switch self {
            case .anotherHostIsRunning(let processIdentifier):
                let detail = processIdentifier.map { " (process \($0))" } ?? ""
                return "Another CLI host is already running\(detail)."
            case .socket(let detail):
                return detail
            }
        }
    }

    private let configuration: Configuration
    private let executor: CommandExecutor
    private let clock: any Clock<Duration>
    private let startedAt = Date()

    private var listeningFileDescriptor: Int32 = -1
    private var acceptSource: (any DispatchSourceProtocol)?
    private let acceptQueue = DispatchQueue(label: "dev.JH.RuntimeViewerCommandLine.HostAccept")
    private var instanceLock: FileLock?
    private var hasWrittenRecord = false

    private var connections: [UUID: SocketConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var idleTask: Task<Void, Never>?

    private var isShuttingDown = false
    private var pendingStopReason: StopReason?
    private var stopReason: StopReason?
    private var stopContinuations: [CheckedContinuation<StopReason, Never>] = []

    public init(configuration: Configuration, executor: CommandExecutor, clock: any Clock<Duration> = ContinuousClock()) {
        self.configuration = configuration
        self.executor = executor
        self.clock = clock
    }

    public var isRunning: Bool {
        listeningFileDescriptor >= 0 && stopReason == nil
    }

    // MARK: - Lifecycle

    /// Takes the instance lock, binds the socket and starts serving.
    ///
    /// The lock is retried for up to two seconds: a host that was just asked to
    /// stop releases it only as it exits, and a client restarting the host, or
    /// the app taking over, reaches this point inside that window.
    public func start() async throws {
        precondition(listeningFileDescriptor < 0, "start() called twice")
        let paths = configuration.paths
        try paths.prepareDirectory()

        guard let lock = try await FileLock.acquire(at: paths.instanceLockURL, timeout: 2) else {
            throw StartError.anotherHostIsRunning(recordedProcessIdentifier: HostRecord.read(from: paths.recordURL)?.processIdentifier)
        }
        instanceLock = lock

        if UnixDomainSocket.isHostListening(at: paths.socketURL.path) {
            lock.release()
            instanceLock = nil
            throw StartError.anotherHostIsRunning(recordedProcessIdentifier: HostRecord.read(from: paths.recordURL)?.processIdentifier)
        }

        do {
            listeningFileDescriptor = try UnixDomainSocket.listen(at: paths.socketURL.path)
        } catch {
            lock.release()
            instanceLock = nil
            throw StartError.socket(String(describing: error))
        }

        let record = HostRecord(
            processIdentifier: getpid(),
            kind: configuration.kind,
            version: configuration.version,
            protocolVersion: CommandLineProtocol.version,
            startedAt: startedAt,
            socketPath: paths.socketURL.path
        )
        do {
            try record.write(to: paths.recordURL)
            hasWrittenRecord = true
        } catch {
            HostLog.write("Could not write \(paths.recordURL.path): \(error)")
        }

        startAccepting()
        rearmIdleTimer()
        HostLog.write("Listening at \(paths.socketURL.path) as \(configuration.kind.rawValue) host, idle timeout \(configuration.idleTimeout.map { "\($0)" } ?? "none")")
        #log(.info, "CLI host listening at \(paths.socketURL.path, privacy: .public)")
    }

    /// Resolves once the host has stopped, with why.
    public func waitUntilStopped() async -> StopReason {
        if let stopReason {
            return stopReason
        }
        return await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
        }
    }

    /// Stops now: in-flight commands are cancelled. For signals.
    public func stop(reason: StopReason) {
        finishStopping(reason: reason)
    }

    public func status() async -> HostStatusResult {
        HostStatusResult(
            processIdentifier: getpid(),
            kind: configuration.kind,
            version: configuration.version,
            protocolVersion: CommandLineProtocol.version,
            startedAt: startedAt,
            activeConnections: connections.count,
            inFlightCommands: requests.count,
            idleTimeout: configuration.idleTimeout.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 },
            isShuttingDown: isShuttingDown,
            loadedImagePaths: await executor.loadedImagePaths()
        )
    }

    // MARK: - Accepting

    private func startAccepting() {
        let listeningFileDescriptor = listeningFileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: listeningFileDescriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            while true {
                let accepted: Int32?
                do {
                    accepted = try UnixDomainSocket.accept(on: listeningFileDescriptor)
                } catch {
                    HostLog.write("accept failed: \(error)")
                    return
                }
                guard let fileDescriptor = accepted else { return }
                guard let self else {
                    close(fileDescriptor)
                    return
                }
                Task { await self.handleAccepted(fileDescriptor) }
            }
        }
        source.setCancelHandler {
            close(listeningFileDescriptor)
        }
        source.resume()
        acceptSource = source
    }

    private func stopAccepting() {
        guard let acceptSource else { return }
        acceptSource.cancel()
        self.acceptSource = nil
        listeningFileDescriptor = -1
    }

    private func handleAccepted(_ fileDescriptor: Int32) {
        guard !isShuttingDown, stopReason == nil else {
            close(fileDescriptor)
            return
        }
        guard let peerUserIdentifier = UnixDomainSocket.peerUserIdentifier(of: fileDescriptor), peerUserIdentifier == getuid() else {
            HostLog.write("Rejected a connection from another user")
            close(fileDescriptor)
            return
        }
        let identifier = UUID()
        let connection = SocketConnection(fileDescriptor: fileDescriptor)
        connections[identifier] = connection
        idleTask?.cancel()
        idleTask = nil
        Task { await self.serve(connection, identifier: identifier) }
    }

    // MARK: - Serving one connection

    private func serve(_ connection: SocketConnection, identifier: UUID) async {
        var didGreet = false
        do {
            for try await payload in connection.incomingPayloads {
                let message: ClientMessage
                do {
                    message = try WireCoding.decode(ClientMessage.self, from: payload)
                } catch {
                    HostLog.write("Dropped an undecodable client message: \(error)")
                    continue
                }
                switch message {
                case .hello(let hello):
                    didGreet = true
                    if hello.protocolVersion != CommandLineProtocol.version {
                        HostLog.write("Client speaks protocol \(hello.protocolVersion), this host speaks \(CommandLineProtocol.version)")
                    }
                    let welcome = Welcome(hostVersion: configuration.version, hostKind: configuration.kind, processIdentifier: getpid())
                    try await connection.send(WireCoding.encodeFrame(HostMessage.welcome(welcome)))
                case .command(let requestIdentifier, let command):
                    guard didGreet else {
                        let failure = CommandFailure(code: .internalError, message: "The connection must start with a hello.")
                        try await connection.send(WireCoding.encodeFrame(HostMessage.failed(requestIdentifier: requestIdentifier, failure: failure)))
                        continue
                    }
                    beginRequest(requestIdentifier, command: command, on: connection)
                case .cancel(let requestIdentifier):
                    requests[requestIdentifier]?.cancel()
                }
            }
        } catch {
            HostLog.write("Connection ended with error: \(error)")
        }
        connectionDidClose(identifier)
    }

    private func connectionDidClose(_ identifier: UUID) {
        guard let connection = connections.removeValue(forKey: identifier) else { return }
        connection.close()
        rearmIdleTimer()
    }

    // MARK: - Requests

    private func beginRequest(_ requestIdentifier: UUID, command: Command, on connection: SocketConnection) {
        let isHostCommand: Bool
        switch command {
        case .hostStatus, .shutdownHost: isHostCommand = true
        default: isHostCommand = false
        }
        if isShuttingDown, !isHostCommand {
            let failure = CommandFailure(code: .hostBusy, message: "The host is shutting down and no longer takes commands.")
            Task { try? await connection.send(WireCoding.encodeFrame(HostMessage.failed(requestIdentifier: requestIdentifier, failure: failure))) }
            return
        }
        idleTask?.cancel()
        idleTask = nil
        HostLog.write("→ \(command.name) [\(requestIdentifier.uuidString.prefix(8))]")
        let task = Task {
            let outcome: HostMessage
            do {
                let result = try await self.perform(command, requestIdentifier: requestIdentifier, on: connection)
                outcome = .completed(requestIdentifier: requestIdentifier, result: result)
            } catch {
                outcome = .failed(requestIdentifier: requestIdentifier, failure: CommandFailure.wrapping(error))
            }
            do {
                try await connection.send(WireCoding.encodeFrame(outcome))
            } catch {
                HostLog.write("Could not deliver the outcome of \(command.name): \(error)")
            }
            self.requestDidFinish(requestIdentifier, command: command)
        }
        requests[requestIdentifier] = task
    }

    private func perform(_ command: Command, requestIdentifier: UUID, on connection: SocketConnection) async throws -> CommandResult {
        switch command {
        case .hostStatus:
            var status = await status()
            // The status request is itself in flight; report what else is.
            status = HostStatusResult(
                processIdentifier: status.processIdentifier,
                kind: status.kind,
                version: status.version,
                protocolVersion: status.protocolVersion,
                startedAt: status.startedAt,
                activeConnections: status.activeConnections,
                inFlightCommands: max(0, status.inFlightCommands - 1),
                idleTimeout: status.idleTimeout,
                isShuttingDown: status.isShuttingDown,
                loadedImagePaths: status.loadedImagePaths
            )
            return .hostStatus(status)
        case .shutdownHost(let reason):
            beginShutdown(reason: reason)
            return .shutdownAcknowledged(ShutdownAcknowledgement(reason: reason, processIdentifier: getpid()))
        default:
            return try await executor.execute(command) { progress in
                try? await connection.send(WireCoding.encodeFrame(HostMessage.progress(requestIdentifier: requestIdentifier, progress: progress)))
            }
        }
    }

    private func requestDidFinish(_ requestIdentifier: UUID, command: Command) {
        requests[requestIdentifier] = nil
        HostLog.write("← \(command.name) [\(requestIdentifier.uuidString.prefix(8))]")
        if isShuttingDown, requests.isEmpty {
            finishStopping(reason: pendingStopReason ?? .shutdownRequested(.userRequest))
            return
        }
        rearmIdleTimer()
    }

    // MARK: - Idle timer

    private func rearmIdleTimer() {
        guard let idleTimeout = configuration.idleTimeout, !isShuttingDown, stopReason == nil, connections.isEmpty, requests.isEmpty else { return }
        idleTask?.cancel()
        idleTask = Task { [clock] in
            do {
                try await clock.sleep(for: idleTimeout)
            } catch {
                return
            }
            self.idleTimerFired()
        }
    }

    private func idleTimerFired() {
        guard connections.isEmpty, requests.isEmpty, !isShuttingDown, stopReason == nil else { return }
        HostLog.write("Idle for \(configuration.idleTimeout.map { "\($0)" } ?? "?"), exiting")
        finishStopping(reason: .idle)
    }

    // MARK: - Shutdown

    /// Stops taking connections; the process exits once the requests in flight
    /// (including the shutdown request itself) have been answered.
    private func beginShutdown(reason: ShutdownReason) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        pendingStopReason = .shutdownRequested(reason)
        HostLog.write("Shutdown requested (\(reason.rawValue)); \(max(0, requests.count - 1)) other command(s) in flight")
        idleTask?.cancel()
        idleTask = nil
        stopAccepting()
        removeSocketFile()
    }

    private func finishStopping(reason: StopReason) {
        guard stopReason == nil else { return }
        stopReason = reason
        isShuttingDown = true
        idleTask?.cancel()
        idleTask = nil
        stopAccepting()
        for task in requests.values {
            task.cancel()
        }
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        removeSocketFile()
        removeRecordIfOwned()
        instanceLock?.release()
        instanceLock = nil
        HostLog.write("Stopped (\(reason))")
        #log(.info, "CLI host stopped: \(String(describing: reason), privacy: .public)")
        let continuations = stopContinuations
        stopContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: reason)
        }
    }

    private func removeSocketFile() {
        unlink(configuration.paths.socketURL.path)
    }

    /// Deletes `host.json` only if this instance wrote it and it still names
    /// this process — an instance that never bound must not delete the file
    /// the winning host's clients rely on (proposal 0006).
    private func removeRecordIfOwned() {
        guard hasWrittenRecord else { return }
        hasWrittenRecord = false
        let recordURL = configuration.paths.recordURL
        guard let record = HostRecord.read(from: recordURL), record.processIdentifier == getpid() else { return }
        try? FileManager.default.removeItem(at: recordURL)
    }
}
