import ArgumentParser
import Foundation

/// Sends one command to the host and prints its outcome.
///
/// Owns the policies the subcommands share: starting a host, retrying a
/// read-only command once when the connection drops, the `--timeout` race,
/// text versus JSON rendering, and the exit codes (0 success, 1 command
/// failure, 69 no host).
public struct CommandRunner: Sendable {
    public static let hostUnavailableExitCode: Int32 = 69

    public var globalOptions: GlobalOptions
    public var output: OutputStreams
    public var launcher: (any HostLaunching)?
    /// Idle timeout handed to a host this runner starts.
    public var spawnIdleTimeout: TimeInterval

    public init(globalOptions: GlobalOptions, output: OutputStreams = .standard, launcher: (any HostLaunching)? = ProcessHostLauncher.forCurrentExecutable(), spawnIdleTimeout: TimeInterval = HostIdleTimeout.resolveDefault()) {
        self.globalOptions = globalOptions
        self.output = output
        self.launcher = launcher
        self.spawnIdleTimeout = spawnIdleTimeout
    }

    public func makeClient(allowsSpawning: Bool? = nil) -> CommandLineHostClient {
        CommandLineHostClient(
            configuration: CommandLineHostClient.Configuration(
                paths: globalOptions.hostPaths,
                allowsSpawning: allowsSpawning ?? !globalOptions.noSpawn,
                spawnIdleTimeout: spawnIdleTimeout
            ),
            launcher: launcher
        )
    }

    /// Runs the command end to end and throws the exit code on failure.
    public func run(_ command: Command) async throws {
        do {
            let result = try await perform(command)
            try emit(result)
        } catch let failure as CommandFailure {
            emit(failure)
            throw ExitCode(1)
        } catch let error as CommandLineHostClient.ClientError {
            emit(CommandFailure(code: .internalError, message: error.description))
            throw ExitCode(error.isUnavailability ? Self.hostUnavailableExitCode : 1)
        } catch let timedOut as Timeouts.TimedOut {
            emit(CommandFailure(code: .cancelled, message: "Gave up after \(Int(timedOut.seconds)) s."))
            throw ExitCode(1)
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            emit(CommandFailure(code: .internalError, message: error.localizedDescription))
            throw ExitCode(1)
        }
    }

    /// Sends the command, starting a host if needed, retrying once on a lost
    /// connection when the command allows it.
    public func perform(_ command: Command) async throws -> CommandResult {
        do {
            return try await sendOnce(command)
        } catch CommandLineHostClient.ClientError.connectionLost where command.isRetryable {
            return try await sendOnce(command)
        }
    }

    private func sendOnce(_ command: Command) async throws -> CommandResult {
        let client = makeClient()
        try await client.connect()
        defer { Task { await client.disconnect() } }
        // Progress goes to standard error whatever the output mode: it never
        // reaches the JSON document on standard output.
        let progressPrinter = ProgressPrinter(output: output)
        let send: @Sendable () async throws -> CommandResult = {
            try await client.send(command) { progress in
                progressPrinter.report(progress)
            }
        }
        let result: CommandResult
        if let timeout = globalOptions.timeout, timeout > 0 {
            result = try await Timeouts.withTimeout(seconds: timeout, operation: send)
        } else {
            result = try await send()
        }
        progressPrinter.finish()
        return result
    }

    public func emit(_ result: CommandResult) throws {
        if globalOptions.json {
            output.writeStandardOutput(try JSONRenderer.render(result))
        } else {
            let rendered = TextRenderer.render(result)
            output.writeStandardOutput(rendered.output)
            for note in rendered.notes {
                output.writeStandardError(note + "\n")
            }
        }
    }

    public func emit(_ failure: CommandFailure) {
        if globalOptions.json {
            output.writeStandardOutput(JSONRenderer.render(failure))
        } else {
            output.writeStandardError(TextRenderer.render(failure))
        }
    }
}

/// The default idle timeout for hosts this tool starts: the
/// `RUNTIME_VIEWER_CLI_IDLE_TIMEOUT` environment variable in seconds, else 600.
public enum HostIdleTimeout {
    public static let environmentVariable = "RUNTIME_VIEWER_CLI_IDLE_TIMEOUT"
    public static let defaultSeconds: TimeInterval = 600

    public static func resolveDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        guard let raw = environment[environmentVariable], let seconds = TimeInterval(raw), seconds >= 0 else {
            return defaultSeconds
        }
        return seconds
    }
}

/// Progress on standard error: one redrawn line on a terminal, sparse lines otherwise.
final class ProgressPrinter: @unchecked Sendable {
    private let output: OutputStreams
    private let lock = NSLock()
    private var lastPhase: String?
    private var lastPrintedFraction = -1
    private var hasDrawnLine = false

    init(output: OutputStreams) {
        self.output = output
    }

    func report(_ progress: CommandProgress) {
        lock.withLock {
            let counter: String
            if let current = progress.current, let total = progress.total, total > 0 {
                counter = " \(current)/\(total)"
            } else {
                counter = ""
            }
            let detail = progress.detail.map { " \($0)" } ?? ""
            let line = "\(progress.phase)\(counter)\(detail)"
            if output.standardErrorIsTerminal {
                output.writeStandardError("\r\u{1B}[2K\(line)")
                hasDrawnLine = true
            } else {
                // Phase changes and every tenth of the way, so a log stays short.
                let fraction: Int
                if let current = progress.current, let total = progress.total, total > 0 {
                    fraction = current * 10 / total
                } else {
                    fraction = -1
                }
                if progress.phase != lastPhase || fraction != lastPrintedFraction {
                    output.writeStandardError(line + "\n")
                    lastPhase = progress.phase
                    lastPrintedFraction = fraction
                }
            }
        }
    }

    func finish() {
        lock.withLock {
            if hasDrawnLine {
                output.writeStandardError("\r\u{1B}[2K")
                hasDrawnLine = false
            }
        }
    }
}
