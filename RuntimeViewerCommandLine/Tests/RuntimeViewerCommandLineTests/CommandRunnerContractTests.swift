import ArgumentParser
import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// The contracts the guide states about what the tool prints and how long it
/// waits: one JSON document on standard output, `--timeout` bounding the whole
/// invocation, and a progress line that never outlives the command.
@Suite("Command runner contracts", .serialized, .timeLimit(.minutes(3)))
struct CommandRunnerContractTests {
    private func makeRunner(
        paths: CommandLineHostPaths,
        extraArguments: [String] = [],
        launcher: (any HostLaunching)? = nil,
        standardErrorIsTerminal: Bool = false
    ) throws -> (CommandRunner, CapturedOutput) {
        let options = try GlobalOptions.parse(["--host-directory", paths.rootDirectory.path] + extraArguments)
        let (streams, captured) = OutputStreams.capturing(standardErrorIsTerminal: standardErrorIsTerminal)
        return (CommandRunner(globalOptions: options, output: streams, launcher: launcher), captured)
    }

    @Test("--timeout bounds waiting for a host that never answers")
    func timeoutCoversConnecting() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        // The launcher reports success and starts nothing, so the client polls
        // the socket until its startup timeout — ten seconds, outside the race
        // that `--timeout` sets up around sending.
        let (runner, _) = try makeRunner(paths: paths, launcher: InProcessHostLauncher(startsHost: false))
        let timedRunner = CommandRunner(
            globalOptions: try GlobalOptions.parse(["--host-directory", paths.rootDirectory.path, "--timeout", "1"]),
            output: runner.output,
            launcher: runner.launcher
        )

        let started = ContinuousClock.now
        _ = try? await timedRunner.perform(.hostStatus)
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(4), "--timeout 1 took \(elapsed): connecting is outside the deadline")
    }

    @Test("--timeout bounds a host that accepts the connection and never greets")
    func timeoutCoversAGreetinglessHost() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        // Accepts, then says nothing. Waiting for the greeting is the one
        // suspension point in connecting that has no timeout of its own.
        let host = try RawTestHost(paths: paths) { _, _ in }
        defer { host.stop() }

        let (runner, _) = try makeRunner(paths: paths, extraArguments: ["--no-spawn", "--timeout", "1"])
        let started = ContinuousClock.now
        _ = try? await runner.perform(.hostStatus)
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(4), "--timeout 1 took \(elapsed) against a host that never greets")
    }

    @Test("host restart --json writes exactly one JSON document")
    func restartWritesOneDocument() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let launcher = InProcessHostLauncher()
        defer { Task { await launcher.stopAll() } }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())

        let (runner, captured) = try makeRunner(paths: paths, extraArguments: ["--json"], launcher: launcher)
        try await HostReporting.restart(runner)

        let documents = captured.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("{") }
        #expect(documents.count == 1, "stdout carried \(documents.count) documents: \(captured.standardOutput)")
        await host.stop()
        await launcher.stopAll()
    }

    @Test("A command that fails clears the progress line it drew")
    func failureClearsTheProgressLine() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let engine = try await TestFoundationEngine.shared()
        let host = try await InProcessHost.start(paths: paths, resolver: LocalSourceResolver(engine: engine))
        let outputDirectory = URL(fileURLWithPath: "/tmp/rvcli-progress-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let (runner, captured) = try makeRunner(
            paths: paths,
            extraArguments: ["--no-spawn", "--timeout", "1"],
            standardErrorIsTerminal: true
        )
        // Exporting Foundation takes seconds, so the deadline lands mid-export,
        // after the progress line has been drawn.
        _ = try? await runner.perform(.export(ExportCommand(
            image: TestFoundationEngine.foundationPath,
            outputDirectory: outputDirectory.path,
            objcLayout: .directory,
            swiftLayout: .directory,
            includeMetadata: false
        )))

        #expect(captured.standardError.contains("exporting"), "No progress line was drawn, so this test proves nothing")
        #expect(
            captured.standardError.hasSuffix("\r\u{1B}[2K"),
            "The progress line was left on the terminal for the error message to land on"
        )
        await host.stop()
    }
}
