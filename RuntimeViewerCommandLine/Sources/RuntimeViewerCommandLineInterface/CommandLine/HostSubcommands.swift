import ArgumentParser
import Darwin
import Foundation

extension RuntimeViewerCommandLineTool {
    public struct Host: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Inspect, stop or restart the background CLI host.",
            subcommands: [Status.self, Stop.self, Restart.self, Run.self],
            defaultSubcommand: Status.self
        )

        public init() {}
    }
}

extension RuntimeViewerCommandLineTool.Host {
    public struct Status: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Show whether a CLI host is running and what it holds.")

        @OptionGroup public var globalOptions: GlobalOptions

        public init() {}

        public func run() async throws {
            let runner = CommandRunner(globalOptions: globalOptions)
            let client = runner.makeClient(allowsSpawning: false)
            do {
                try await client.connect()
            } catch let error as CommandLineHostClient.ClientError where error.isUnavailability {
                try HostReporting.reportNoHost(runner)
                return
            }
            defer { Task { await client.disconnect() } }
            let result = try await HostReporting.perform(.hostStatus, with: client, runner: runner)
            try runner.emit(result)
        }
    }

    public struct Stop: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Ask the running CLI host to exit once its commands in flight finish.")

        @OptionGroup public var globalOptions: GlobalOptions

        public init() {}

        public func run() async throws {
            let runner = CommandRunner(globalOptions: globalOptions)
            guard try await HostReporting.stopRunningHost(runner) else {
                try HostReporting.reportNoHost(runner)
                return
            }
        }
    }

    public struct Restart: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Stop the running CLI host, if any, and start a fresh one.")

        @OptionGroup public var globalOptions: GlobalOptions

        public init() {}

        public func run() async throws {
            let runner = CommandRunner(globalOptions: globalOptions)
            _ = try await HostReporting.stopRunningHost(runner)
            let client = runner.makeClient(allowsSpawning: true)
            do {
                try await client.connect()
            } catch let error as CommandLineHostClient.ClientError {
                runner.emit(CommandFailure(code: .internalError, message: error.description))
                throw ExitCode(error.isUnavailability ? CommandRunner.hostUnavailableExitCode : 1)
            }
            defer { Task { await client.disconnect() } }
            let result = try await HostReporting.perform(.hostStatus, with: client, runner: runner)
            try runner.emit(result)
        }
    }

    /// Runs the host in this process. Started by the client in the background;
    /// run it in the foreground to watch its log directly.
    public struct Run: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Run a CLI host in the foreground (what the client starts in the background).")

        @Option(name: .customLong("idle-timeout"), help: ArgumentHelp("Exit after this many seconds without connections or commands; 0 never exits.", valueName: "seconds"))
        public var idleTimeout: Double = HostIdleTimeout.resolveDefault()

        @Option(name: .customLong("host-directory"), help: ArgumentHelp("Directory for the socket and records.", valueName: "path"))
        public var hostDirectory: String?

        public init() {}

        public func run() async throws {
            let paths = CommandLineHostPaths.resolveDefault(override: hostDirectory)
            let resolver = LocalSourceResolver()
            let executor = CommandExecutor(sourceResolver: resolver)
            let server = CommandLineHostServer(
                configuration: CommandLineHostServer.Configuration(
                    paths: paths,
                    kind: .standalone,
                    idleTimeout: idleTimeout > 0 ? .seconds(idleTimeout) : nil
                ),
                executor: executor
            )
            do {
                try await server.start()
            } catch {
                HostLog.write("Not starting: \(error)")
                throw ExitCode(CommandRunner.hostUnavailableExitCode)
            }

            let signalSources = SignalForwarding.install(signals: [SIGTERM, SIGINT, SIGHUP]) {
                Task { await server.stop(reason: .signal) }
            }
            let reason = await server.waitUntilStopped()
            withExtendedLifetime(signalSources) {}
            await executor.shutdown()
            if case .signal = reason {
                throw ExitCode(0)
            }
        }
    }
}

/// Steps the host subcommands share.
enum HostReporting {
    static func reportNoHost(_ runner: CommandRunner) throws {
        if runner.globalOptions.json {
            runner.output.writeStandardOutput(try JSONRenderer.render(NoHostDocument()))
        } else {
            runner.output.writeStandardOutput("No CLI host is running.\n")
        }
    }

    static func perform(_ command: Command, with client: CommandLineHostClient, runner: CommandRunner) async throws -> CommandResult {
        do {
            return try await client.send(command)
        } catch let failure as CommandFailure {
            runner.emit(failure)
            throw ExitCode(1)
        } catch let error as CommandLineHostClient.ClientError {
            runner.emit(CommandFailure(code: .internalError, message: error.description))
            throw ExitCode(error.isUnavailability ? CommandRunner.hostUnavailableExitCode : 1)
        }
    }

    /// Sends a shutdown to a running host and waits for its socket to go away.
    /// - Returns: `false` when no host was running.
    static func stopRunningHost(_ runner: CommandRunner) async throws -> Bool {
        let client = runner.makeClient(allowsSpawning: false)
        do {
            try await client.connect()
        } catch let error as CommandLineHostClient.ClientError where error.isUnavailability {
            return false
        }
        let paths = runner.globalOptions.hostPaths
        let record = HostRecord.read(from: paths.recordURL)
        let result = try await perform(.shutdownHost(.userRequest), with: client, runner: runner)
        await client.disconnect()
        // The host unlinks its socket as soon as it starts draining, but keeps
        // the instance lock until it exits; wait for the exit itself so a host
        // started right after this does not collide with it.
        for _ in 0 ..< 50 where isHostStillExiting(record: record, paths: paths) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try runner.emit(result)
        return true
    }

    private static func isHostStillExiting(record: HostRecord?, paths: CommandLineHostPaths) -> Bool {
        if UnixDomainSocket.isHostListening(at: paths.socketURL.path) {
            return true
        }
        if FileManager.default.fileExists(atPath: paths.recordURL.path) {
            return true
        }
        guard let record else { return false }
        return kill(record.processIdentifier, 0) == 0
    }

    private struct NoHostDocument: Encodable {
        let running = false
    }
}

/// Turns signals into a callback without touching the main run loop.
enum SignalForwarding {
    static func install(signals: [Int32], handler: @escaping @Sendable () -> Void) -> [any DispatchSourceProtocol] {
        let queue = DispatchQueue(label: "dev.JH.RuntimeViewerCommandLine.Signals")
        return signals.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}
