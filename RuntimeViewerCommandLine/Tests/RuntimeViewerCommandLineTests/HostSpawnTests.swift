import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// How a client finds a host: connect, and only if nothing answers take the
/// lock, try once more, start one, and poll until it answers.
@Suite("Host spawning", .serialized, .timeLimit(.minutes(1)))
struct HostSpawnTests {
    @Test("A client that finds no host starts one and connects to it")
    func clientStartsHost() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let launcher = InProcessHostLauncher()
        let client = makeClient(paths: paths, allowsSpawning: true, launcher: launcher)

        let welcome = try await client.connect()

        #expect(launcher.launchCount == 1)
        #expect(welcome.hostKind == .standalone)
        #expect(welcome.processIdentifier == getpid())
        let record = try #require(HostRecord.read(from: paths.recordURL))
        #expect(record.socketPath == paths.socketURL.path)
        await client.disconnect()
        await launcher.stopAll()
    }

    @Test("With spawning disabled a missing host is an error, not a launch")
    func noSpawnFails() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let launcher = InProcessHostLauncher()
        let client = makeClient(paths: paths, allowsSpawning: false, launcher: launcher)

        await #expect(throws: CommandLineHostClient.ClientError.self) {
            try await client.connect()
        }
        #expect(launcher.launchCount == 0)
    }

    @Test("A client without a launcher reports the host as unreachable")
    func noLauncherFails() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let client = makeClient(paths: paths, allowsSpawning: true, launcher: nil)
        do {
            try await client.connect()
            Issue.record("Connected without a host")
        } catch let error as CommandLineHostClient.ClientError {
            #expect(error.isUnavailability)
        }
    }

    @Test("Two clients racing for a missing host start exactly one")
    func concurrentClientsStartOneHost() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let launcher = InProcessHostLauncher()
        let first = makeClient(paths: paths, allowsSpawning: true, launcher: launcher)
        let second = makeClient(paths: paths, allowsSpawning: true, launcher: launcher)

        async let firstWelcome = first.connect()
        async let secondWelcome = second.connect()
        let welcomes = try await [firstWelcome, secondWelcome]

        #expect(launcher.launchCount == 1)
        #expect(welcomes.allSatisfy { $0.processIdentifier == getpid() })
        await first.disconnect()
        await second.disconnect()
        await launcher.stopAll()
    }

    @Test("A host that never answers is reported after the startup timeout")
    func hostThatNeverStarts() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let launcher = InProcessHostLauncher(startsHost: false)
        let client = makeClient(paths: paths, allowsSpawning: true, launcher: launcher, startupTimeout: 0.5)

        do {
            try await client.connect()
            Issue.record("Connected without a host")
        } catch let error as CommandLineHostClient.ClientError {
            guard case .hostDidNotStart = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(error.isUnavailability)
        }
        #expect(launcher.launchCount == 1)
    }

    @Test("A client connects to a host that is already running without launching")
    func existingHostIsReused() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())
        let launcher = InProcessHostLauncher()
        let client = makeClient(paths: paths, allowsSpawning: true, launcher: launcher)

        _ = try await client.connect()

        #expect(launcher.launchCount == 0)
        await client.disconnect()
        await host.stop()
    }

    @Test("A stale socket file from a dead host is replaced")
    func staleSocketIsReplaced() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        // A socket file nobody listens on, as a crashed host leaves behind.
        let staleListener = try UnixDomainSocket.listen(at: paths.socketURL.path)
        close(staleListener)
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))

        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())
        let client = makeClient(paths: paths)
        _ = try await client.connect()
        await client.disconnect()
        await host.stop()
    }
}
