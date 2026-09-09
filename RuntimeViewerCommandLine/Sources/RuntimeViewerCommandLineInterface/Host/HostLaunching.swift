import Darwin
import Foundation

/// Starts a host process. The client's only way to create one; tests substitute
/// something that starts a host in-process.
public protocol HostLaunching: Sendable {
    /// Starts a host for `paths` that exits after `idleTimeout` seconds without
    /// connections or commands (`0` keeps it alive until stopped).
    func launchHost(paths: CommandLineHostPaths, idleTimeout: TimeInterval) throws
}

/// Spawns `<executable> host run` detached from the terminal, with its output
/// appended to `host.log`.
public struct ProcessHostLauncher: HostLaunching {
    public enum LaunchError: Error, CustomStringConvertible {
        case spawnFailed(code: Int32, executable: String)

        public var description: String {
            switch self {
            case .spawnFailed(let code, let executable):
                return "Could not start '\(executable)': \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// A launcher for the running tool itself.
    public static func forCurrentExecutable() -> ProcessHostLauncher? {
        Bundle.main.executableURL.map(ProcessHostLauncher.init)
    }

    public func launchHost(paths: CommandLineHostPaths, idleTimeout: TimeInterval) throws {
        try paths.prepareDirectory()
        let arguments = [
            executableURL.lastPathComponent,
            "host", "run",
            "--idle-timeout", String(Int(idleTimeout.rounded())),
            "--host-directory", paths.rootDirectory.path,
        ]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, paths.logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // POSIX_SPAWN_SETSID (0x0400): its own session, so a closing terminal
        // does not take the host with it. POSIX_SPAWN_CLOEXEC_DEFAULT (0x4000):
        // nothing but the three redirected descriptors is inherited — in
        // particular not the client's `host.lock` descriptor, whose `flock`
        // would otherwise outlive the client and wedge every later client.
        posix_spawnattr_setflags(&attributes, Int16(0x0400 | 0x4000))

        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer { cArguments.forEach { free($0) } }
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer { cEnvironment.forEach { free($0) } }

        var processIdentifier: pid_t = 0
        let status = posix_spawn(&processIdentifier, executableURL.path, &fileActions, &attributes, cArguments, cEnvironment)
        guard status == 0 else {
            throw LaunchError.spawnFailed(code: status, executable: executableURL.path)
        }
    }
}
