import Darwin
import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// The app taking over from a standalone host, and stepping aside for
/// another app; both against hosts running inside the test process.
@Suite("Host takeover", .serialized, .timeLimit(.minutes(1)))
struct HostTakeoverTests {
    @Test("With no host the way is clear")
    func noHost() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }

        #expect(await HostTakeover.claim(paths: paths) == .noHost)
    }

    @Test("A standalone host is asked to leave for the application and does")
    func standaloneHostIsRetired() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())

        let outcome = await HostTakeover.claim(paths: paths)

        #expect(outcome == .tookOver(processIdentifier: getpid(), exited: true))
        #expect(await resolves(within: 5) { await host.server.waitUntilStopped() } == .shutdownRequested(.applicationTakeover))
        #expect(!UnixDomainSocket.isHostListening(at: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.recordURL.path))

        // The application can now bind where the standalone host was.
        let applicationHost = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), kind: .application)
        defer { Task { await applicationHost.stop() } }
        #expect(await applicationHost.server.isRunning)
    }

    @Test("Another application host is left alone")
    func applicationHostIsLeftAlone() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), kind: .application)
        defer { Task { await host.stop() } }

        let outcome = await HostTakeover.claim(paths: paths)

        #expect(outcome == .anotherApplicationHost(processIdentifier: getpid()))
        #expect(await host.server.isRunning)
        #expect(UnixDomainSocket.isHostListening(at: paths.socketURL.path))
    }

    @Test("A client with the newer protocol replaces a standalone host that speaks the older one")
    func outdatedStandaloneHostIsRetiredByTheClient() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let outdated = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver(), kind: .standalone, protocolVersion: CommandLineProtocol.version - 1)
        let launcher = InProcessHostLauncher(resolver: StubSourceResolver())
        let client = makeClient(paths: paths, allowsSpawning: true, launcher: launcher)
        defer { Task { await client.disconnect(); await launcher.stopAll() } }

        let welcome = try await client.connect()

        #expect(welcome.protocolVersion == CommandLineProtocol.version)
        #expect(await resolves(within: 5) { await outdated.server.waitUntilStopped() } == .shutdownRequested(.userRequest))
        #expect(launcher.launchCount == 1)
    }

    @Test("Synchronous artifact removal only touches a record that names this process")
    func synchronousArtifactRemoval() throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        try Data().write(to: paths.socketURL)

        try HostRecord(processIdentifier: 1, kind: .application, version: "0", protocolVersion: 1, startedAt: Date(), socketPath: paths.socketURL.path).write(to: paths.recordURL)
        CommandLineHostServer.removeArtifactsSynchronously(at: paths)
        #expect(FileManager.default.fileExists(atPath: paths.recordURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))

        try HostRecord(processIdentifier: getpid(), kind: .application, version: "0", protocolVersion: 1, startedAt: Date(), socketPath: paths.socketURL.path).write(to: paths.recordURL)
        CommandLineHostServer.removeArtifactsSynchronously(at: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.recordURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
    }
}
