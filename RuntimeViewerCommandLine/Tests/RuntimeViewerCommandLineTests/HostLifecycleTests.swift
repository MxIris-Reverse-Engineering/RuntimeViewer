import Clocks
import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// The host exits on its own only when nothing is connected and nothing is in
/// flight for the whole idle timeout. Driven by a test clock, so no test waits.
@Suite("Host idle exit", .serialized, .timeLimit(.minutes(1)))
struct HostIdleExitTests {
    @Test("A host nobody talks to exits when the idle timeout elapses")
    func idleHostExits() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let clock = TestClock()
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), idleTimeout: .seconds(600), clock: clock)
        await settle()

        await clock.advance(by: .seconds(599))
        #expect(await host.server.isRunning)

        await clock.advance(by: .seconds(1))
        let reason = await resolves(within: 5) { await host.server.waitUntilStopped() }
        #expect(reason == .idle)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.recordURL.path))
    }

    @Test("An open connection keeps the host alive; closing it restarts the countdown")
    func connectionKeepsHostAlive() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let clock = TestClock()
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), idleTimeout: .seconds(600), clock: clock)
        await settle()

        let client = makeClient(paths: paths)
        try await client.connect()
        await settle()

        await clock.advance(by: .seconds(1_000))
        #expect(await host.server.isRunning)
        #expect(await resolves(within: 0.3) { await host.server.waitUntilStopped() } == nil)

        await client.disconnect()
        await settle(milliseconds: 300)

        await clock.advance(by: .seconds(600))
        let reason = await resolves(within: 5) { await host.server.waitUntilStopped() }
        #expect(reason == .idle)
    }

    @Test("A command in flight keeps the host alive even with no other traffic")
    func inFlightCommandKeepsHostAlive() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let clock = TestClock()
        let resolver = StubSourceResolver(blocking: true)
        let host = try await InProcessHost.start(paths: paths, resolver: resolver, idleTimeout: .seconds(600), clock: clock)
        await settle()

        let client = makeClient(paths: paths)
        try await client.connect()
        let commandTask = Task {
            try await client.send(.listImages(ListImagesCommand()))
        }
        await settle(milliseconds: 300)
        #expect(await resolver.resolveCount == 1)

        await clock.advance(by: .seconds(1_000))
        #expect(await host.server.isRunning)

        await resolver.release()
        await #expect(throws: CommandFailure.self) {
            try await commandTask.value
        }
        await client.disconnect()
        await settle(milliseconds: 300)

        await clock.advance(by: .seconds(600))
        let reason = await resolves(within: 5) { await host.server.waitUntilStopped() }
        #expect(reason == .idle)
    }

    @Test("A host without an idle timeout stays up")
    func noIdleTimeoutNeverExits() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let clock = TestClock()
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), idleTimeout: nil, clock: clock)
        await settle()
        await clock.advance(by: .seconds(100_000))
        #expect(await host.server.isRunning)
        await host.stop()
    }
}

@Suite("Host shutdown requests", .serialized, .timeLimit(.minutes(1)))
struct HostShutdownTests {
    @Test("A user-requested shutdown is acknowledged and leaves no files behind", arguments: [ShutdownReason.userRequest, .applicationTakeover])
    func shutdownIsAcknowledged(reason: ShutdownReason) async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())
        let client = makeClient(paths: paths)
        try await client.connect()

        let result = try await client.send(.shutdownHost(reason))
        #expect(result == .shutdownAcknowledged(ShutdownAcknowledgement(reason: reason, processIdentifier: getpid())))

        let stopReason = await resolves(within: 5) { await host.server.waitUntilStopped() }
        #expect(stopReason == .shutdownRequested(reason))
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.recordURL.path))
        // The instance lock is free again, so a new host can take it.
        let lock = try FileLock.tryAcquire(at: paths.instanceLockURL)
        #expect(lock != nil)
        lock?.release()
    }

    @Test("A shutdown waits for the command in flight and refuses new ones")
    func shutdownDrainsInFlightCommands() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let resolver = StubSourceResolver(blocking: true)
        let host = try await InProcessHost.start(paths: paths, resolver: resolver)
        let client = makeClient(paths: paths)
        try await client.connect()

        let blocked = Task { try await client.send(.listImages(ListImagesCommand())) }
        await settle(milliseconds: 300)
        #expect(await resolver.resolveCount == 1)

        let acknowledgement = try await client.send(.shutdownHost(.userRequest))
        guard case .shutdownAcknowledged = acknowledgement else {
            Issue.record("Unexpected result \(acknowledgement)")
            return
        }
        // Still draining: the blocked command has not finished.
        #expect(await resolves(within: 0.3) { await host.server.waitUntilStopped() } == nil)

        // New work is refused while draining.
        await #expect(throws: CommandFailure.self) {
            try await client.send(.hostStatusProbe)
        }

        await resolver.release()
        await #expect(throws: CommandFailure.self) { try await blocked.value }
        let stopReason = await resolves(within: 5) { await host.server.waitUntilStopped() }
        #expect(stopReason == .shutdownRequested(.userRequest))
    }

    @Test("Status reports the host's kind and what is connected")
    func statusReflectsConnections() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), kind: .application, idleTimeout: .seconds(42))
        let client = makeClient(paths: paths)
        let welcome = try await client.connect()
        #expect(welcome.hostKind == .application)
        #expect(welcome.protocolVersion == CommandLineProtocol.version)

        let result = try await client.send(.hostStatus)
        guard case .hostStatus(let status) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(status.kind == .application)
        #expect(status.processIdentifier == getpid())
        #expect(status.activeConnections == 1)
        #expect(status.inFlightCommands == 0)
        #expect(status.idleTimeout == 42)
        #expect(status.isShuttingDown == false)

        let record = try #require(HostRecord.read(from: paths.recordURL))
        #expect(record.processIdentifier == getpid())
        #expect(record.kind == .application)
        await host.stop()
    }

    @Test("A host waits briefly for the instance lock a stopping host still holds")
    func startWaitsForInstanceLock() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let lock = try #require(try FileLock.tryAcquire(at: paths.instanceLockURL))
        let starting = Task {
            try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())
        }
        await settle(milliseconds: 300)
        lock.release()
        let host = try await starting.value
        #expect(await host.server.isRunning)
        await host.stop()
    }

    @Test("A second host on the same directory refuses to start")
    func secondHostRefuses() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let first = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())
        await #expect(throws: CommandLineHostServer.StartError.self) {
            _ = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())
        }
        await first.stop()
    }
}

extension Command {
    /// An engine command that the stub resolver answers with `sourceUnavailable`
    /// unless the host is draining, in which case the host answers `hostBusy`.
    static var hostStatusProbe: Command { .listTypes(ListTypesCommand()) }
}
