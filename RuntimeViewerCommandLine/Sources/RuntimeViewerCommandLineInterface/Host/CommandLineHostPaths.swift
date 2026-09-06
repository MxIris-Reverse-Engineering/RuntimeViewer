import Foundation

/// Where a host keeps its socket and bookkeeping files.
///
/// Default: `~/Library/Application Support/RuntimeViewer[-Debug]/CommandLineHost/`.
/// The `-Debug` suffix follows the app's settings directory, so a Debug tool
/// pairs with the Debug app and never with the released one. Tests point at a
/// temporary directory.
public struct CommandLineHostPaths: Sendable, Hashable {
    public static let environmentVariable = "RUNTIME_VIEWER_CLI_HOST_DIRECTORY"

    #if DEBUG
    public static let applicationDirectoryName = "RuntimeViewer-Debug"
    #else
    public static let applicationDirectoryName = "RuntimeViewer"
    #endif

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    /// The directory to use, in order of preference: an explicit override, the
    /// environment variable, the default under Application Support.
    public static func resolveDefault(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> CommandLineHostPaths {
        if let override, !override.isEmpty {
            return CommandLineHostPaths(rootDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        if let fromEnvironment = environment[environmentVariable], !fromEnvironment.isEmpty {
            return CommandLineHostPaths(rootDirectory: URL(fileURLWithPath: fromEnvironment, isDirectory: true))
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return CommandLineHostPaths(
            rootDirectory: applicationSupport
                .appendingPathComponent(applicationDirectoryName, isDirectory: true)
                .appendingPathComponent("CommandLineHost", isDirectory: true)
        )
    }

    /// The listening socket.
    public var socketURL: URL { rootDirectory.appendingPathComponent("host.sock") }
    /// Serializes clients that found no host, so only one of them starts one.
    public var clientLockURL: URL { rootDirectory.appendingPathComponent("host.lock") }
    /// Held by the running host; a second host fails to take it and exits.
    public var instanceLockURL: URL { rootDirectory.appendingPathComponent("host.pid") }
    /// Describes the running host (`HostRecord`).
    public var recordURL: URL { rootDirectory.appendingPathComponent("host.json") }
    /// Standard output and error of a host the client started.
    public var logURL: URL { rootDirectory.appendingPathComponent("host.log") }

    /// Creates the directory, readable by the owner only.
    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

/// What `host.json` holds while a host runs.
public struct HostRecord: Codable, Sendable, Hashable {
    public let processIdentifier: Int32
    public let kind: HostKind
    public let version: String
    public let protocolVersion: Int
    public let startedAt: Date
    public let socketPath: String

    public init(processIdentifier: Int32, kind: HostKind, version: String, protocolVersion: Int, startedAt: Date, socketPath: String) {
        self.processIdentifier = processIdentifier
        self.kind = kind
        self.version = version
        self.protocolVersion = protocolVersion
        self.startedAt = startedAt
        self.socketPath = socketPath
    }

    public static func read(from url: URL) -> HostRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? WireCoding.makeDecoder().decode(HostRecord.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = WireCoding.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(self).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}

/// Timestamped lines on standard error. When the client started the host,
/// standard error is `host.log`.
enum HostLog {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(getpid())] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
