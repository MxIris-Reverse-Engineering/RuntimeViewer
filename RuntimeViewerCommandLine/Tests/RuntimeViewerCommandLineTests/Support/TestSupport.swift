import Clocks
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerCommandLineInterface

/// A short directory under `/tmp` for a host's socket. The system temporary
/// directory is too deep: `sockaddr_un` holds 104 bytes and
/// `/var/folders/…/T/` alone uses half of them.
enum TemporaryHostDirectory {
    static func make() throws -> CommandLineHostPaths {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let paths = CommandLineHostPaths(rootDirectory: URL(fileURLWithPath: "/tmp/rvcli-\(suffix)", isDirectory: true))
        try paths.prepareDirectory()
        return paths
    }

    static func remove(_ paths: CommandLineHostPaths) {
        try? FileManager.default.removeItem(at: paths.rootDirectory)
    }
}

/// One connected in-process engine per test process with libobjc indexed.
/// Shared because indexing costs seconds; nothing may load further images
/// into it, so every test sees the same state.
enum TestLocalEngine {
    static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    private static let sharedTask = Task<RuntimeEngine, any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeViewerCommandLineTests.shared")
        try await engine.connect()
        _ = try await engine.objects(in: libobjcPath)
        return engine
    }

    static func shared() async throws -> RuntimeEngine {
        try await sharedTask.value
    }
}

/// A resolver that never reaches an engine: `resolve` fails with
/// `sourceUnavailable` at once, or, when created blocking, only after
/// `release()` — which keeps a command in flight for as long as a test wants.
actor StubSourceResolver: SourceResolving {
    private var isBlocking: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resolveCount = 0

    init(blocking: Bool = false) {
        isBlocking = blocking
    }

    func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine {
        resolveCount += 1
        if isBlocking {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        throw CommandFailure(code: .sourceUnavailable, message: "stub")
    }

    func loadedImagePaths() async -> [String] { [] }

    func shutdown() async {}

    func release() {
        isBlocking = false
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// A host running inside the test process.
final class InProcessHost: Sendable {
    let paths: CommandLineHostPaths
    let server: CommandLineHostServer
    let executor: CommandExecutor

    private init(paths: CommandLineHostPaths, server: CommandLineHostServer, executor: CommandExecutor) {
        self.paths = paths
        self.server = server
        self.executor = executor
    }

    static func start(
        paths: CommandLineHostPaths,
        resolver: any SourceResolving,
        kind: HostKind = .standalone,
        idleTimeout: Duration? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> InProcessHost {
        let executor = CommandExecutor(sourceResolver: resolver)
        let server = CommandLineHostServer(
            configuration: CommandLineHostServer.Configuration(paths: paths, kind: kind, idleTimeout: idleTimeout),
            executor: executor,
            clock: clock
        )
        try await server.start()
        return InProcessHost(paths: paths, server: server, executor: executor)
    }

    /// A host serving the shared local engine.
    static func startWithSharedEngine(paths: CommandLineHostPaths) async throws -> InProcessHost {
        try await start(paths: paths, resolver: LocalSourceResolver(engine: try await TestLocalEngine.shared()))
    }

    func stop() async {
        await server.stop(reason: .signal)
    }
}

/// Starts an in-process host when the client asks for one, the way the real
/// launcher starts a process. Counts how often it was asked.
final class InProcessHostLauncher: HostLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var launchCountStorage = 0
    private var hosts: [InProcessHost] = []
    private let resolver: any SourceResolving
    /// When false, the launcher pretends to start a host and never does.
    private let startsHost: Bool

    init(resolver: any SourceResolving = StubSourceResolver(), startsHost: Bool = true) {
        self.resolver = resolver
        self.startsHost = startsHost
    }

    var launchCount: Int {
        lock.withLock { launchCountStorage }
    }

    func launchHost(paths: CommandLineHostPaths, idleTimeout: TimeInterval) throws {
        lock.withLock { launchCountStorage += 1 }
        guard startsHost else { return }
        let resolver = resolver
        Task {
            let host = try await InProcessHost.start(paths: paths, resolver: resolver, idleTimeout: idleTimeout > 0 ? .seconds(idleTimeout) : nil)
            self.lock.withLock { self.hosts.append(host) }
        }
    }

    func stopAll() async {
        let hosts = lock.withLock { self.hosts }
        for host in hosts {
            await host.stop()
        }
    }
}

func makeClient(paths: CommandLineHostPaths, allowsSpawning: Bool = false, launcher: (any HostLaunching)? = nil, startupTimeout: TimeInterval = 10) -> CommandLineHostClient {
    CommandLineHostClient(
        configuration: CommandLineHostClient.Configuration(paths: paths, allowsSpawning: allowsSpawning, spawnIdleTimeout: 0, startupTimeout: startupTimeout, lockTimeout: 5),
        launcher: launcher
    )
}

/// Lets the host notice a connection change or register its idle sleep.
func settle(milliseconds: Int = 100) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// The value an awaitable produces within `seconds`, or `nil`.
///
/// Polls a detached task instead of racing inside a task group: a group
/// waits for its children, and `waitUntilStopped()` does not react to
/// cancellation, so a group-based race would block until the host stops.
func resolves<Value: Sendable>(within seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Value) async -> Value? {
    let box = ResultBox<Value>()
    Task {
        let value = await operation()
        await box.set(value)
    }
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if let value = await box.value {
            return value
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await box.value
}

actor ResultBox<Value: Sendable> {
    private(set) var value: Value?

    func set(_ newValue: Value) {
        value = newValue
    }
}

/// One connected engine per test process with Foundation indexed. Foundation is
/// what makes an export long enough to interrupt: libobjc finishes before a
/// cancellation could be told apart from completion.
enum TestFoundationEngine {
    static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

    private static let sharedTask = Task<RuntimeEngine, any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeViewerCommandLineTests.foundation")
        try await engine.connect()
        _ = try await engine.objects(in: foundationPath)
        return engine
    }

    static func shared() async throws -> RuntimeEngine {
        try await sharedTask.value
    }
}

/// A host made of a raw socket, so a test can send frames the real host never
/// would: a corrupt one, or a `Welcome` that names another process.
///
/// The real server owns its accept loop through a `DispatchSource`; this one
/// polls, which is enough for a single connection in a test.
final class RawTestHost: @unchecked Sendable {
    typealias Responder = @Sendable (SocketConnection, ClientMessage) async -> Void

    private let listeningFileDescriptor: Int32
    private let acceptTask: Task<Void, Never>

    init(paths: CommandLineHostPaths, respond: @escaping Responder) throws {
        try paths.prepareDirectory()
        let fileDescriptor = try UnixDomainSocket.listen(at: paths.socketURL.path)
        listeningFileDescriptor = fileDescriptor
        acceptTask = Task.detached {
            while !Task.isCancelled {
                guard let accepted = try? UnixDomainSocket.accept(on: fileDescriptor), accepted >= 0 else {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                let connection = SocketConnection(fileDescriptor: accepted)
                Task {
                    do {
                        for try await payload in connection.incomingPayloads {
                            guard let message = try? WireCoding.decode(ClientMessage.self, from: payload) else { continue }
                            await respond(connection, message)
                        }
                    } catch {
                        // The client hung up; nothing else to serve.
                    }
                }
            }
        }
    }

    func stop() {
        acceptTask.cancel()
        close(listeningFileDescriptor)
    }
}
