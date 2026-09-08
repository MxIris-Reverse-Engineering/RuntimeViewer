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

    @Test("Stopping a host prints nothing by itself, so host restart --json stays one document")
    func stoppingAHostDoesNotPrint() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())

        let (runner, captured) = try makeRunner(paths: paths, extraArguments: ["--no-spawn", "--json"])
        let acknowledgement = try await HostReporting.stopRunningHost(runner)

        #expect(acknowledgement != nil, "The running host was not stopped")
        #expect(
            captured.standardOutput.isEmpty,
            "stopRunningHost printed on its own; `host restart --json` then emits a second document after it"
        )
        await host.stop()
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
