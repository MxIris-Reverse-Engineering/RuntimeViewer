import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// What the client does when the other end of the socket is not the host it
/// expects: two callers connecting at once, a frame it cannot decode, and a
/// greeting that names a process the client is about to signal.
@Suite("Client robustness", .serialized, .timeLimit(.minutes(2)))
struct ClientRobustnessTests {
    @Test("Two connects on one client both get an answer")
    func concurrentConnectsBothReturn() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())

        let client = makeClient(paths: paths)
        let first = Task { try await client.connect() }
        let second = Task { try await client.connect() }

        let bothAnswered = await resolves(within: 5) { () -> Bool in
            let firstWelcome = try? await first.value
            let secondWelcome = try? await second.value
            return firstWelcome != nil && secondWelcome != nil
        }

        #expect(bothAnswered == true, "One connect never returned: its continuation was replaced by the other's")
        first.cancel()
        second.cancel()
        await host.stop()
    }

    @Test("An undecodable frame is dropped, not taken for the connection dying")
    func undecodableFrameKeepsTheConnection() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try RawTestHost(paths: paths) { connection, message in
            switch message {
            case .hello:
                let welcome = Welcome(hostKind: .standalone, processIdentifier: getpid())
                try? await connection.send(WireCoding.encodeFrame(HostMessage.welcome(welcome)))
            case .command(let requestIdentifier, _):
                // Something this client cannot decode, then a good answer. The
                // host does exactly this in reverse: it logs and reads on.
                try? await connection.send(try FrameCodec.encodeFrame(payload: Data([0x00, 0x01, 0x02])))
                let failure = CommandFailure(code: .typeNotFound, message: "answered after the bad frame")
                try? await connection.send(WireCoding.encodeFrame(HostMessage.failed(requestIdentifier: requestIdentifier, failure: failure)))
            case .cancel:
                break
            }
        }
        defer { host.stop() }

        let client = makeClient(paths: paths)
        try await client.connect()

        var failure: CommandFailure?
        do {
            _ = try await client.send(.hostStatus)
        } catch let error as CommandFailure {
            failure = error
        } catch {
            // A connectionLost here is the defect: one bad frame took the
            // whole connection down and the answer that followed was lost.
        }

        #expect(failure?.code == .typeNotFound, "The frame after the undecodable one never arrived")
        await client.disconnect()
    }

    @Test("An outdated host cannot make the client signal a process of its choosing")
    func outdatedHostCannotSignalAnArbitraryProcess() async throws {
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["30"]
        try victim.run()
        defer { if victim.isRunning { victim.terminate() } }
        let victimProcessIdentifier = victim.processIdentifier

        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        // Speaks a protocol the client does not, names the victim as its own
        // process, and never acts on a shutdown request — so the client falls
        // through to signalling the process it was told about. No `host.json`
        // is written, so nothing corroborates the claim.
        let host = try RawTestHost(paths: paths) { connection, message in
            guard case .hello = message else { return }
            let welcome = Welcome(protocolVersion: CommandLineProtocol.version + 998, hostVersion: "outdated", hostKind: .standalone, processIdentifier: victimProcessIdentifier)
            try? await connection.send(WireCoding.encodeFrame(HostMessage.welcome(welcome)))
        }
        defer { host.stop() }

        let client = makeClient(paths: paths, allowsSpawning: true, launcher: InProcessHostLauncher(startsHost: false), startupTimeout: 1)
        _ = try? await client.connect()

        try await Task.sleep(for: .milliseconds(500))
        #expect(victim.isRunning, "The client SIGTERMed a process the host merely claimed to be")
        await client.disconnect()
    }
}
