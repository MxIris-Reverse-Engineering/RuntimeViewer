import Foundation

/// Constants of the client ↔ host protocol.
public enum CommandLineProtocol {
    /// Bumped whenever a message shape changes incompatibly. A client and a
    /// host that disagree do not talk; see `CommandLineHostClient.connect()`.
    public static let version = 1
}

/// Version of the tool and of the host it starts.
public enum CommandLineToolVersion {
    public static let current = "0.1.0"
}

/// Who is answering on the socket.
public enum HostKind: String, Codable, Sendable, Hashable {
    /// The background process `runtime-viewer-cli host run` started.
    case standalone
    /// The RuntimeViewer app.
    case application
}

/// First message on every connection, sent by the client.
public struct Hello: Codable, Sendable, Hashable {
    public let protocolVersion: Int
    public let clientVersion: String

    public init(protocolVersion: Int = CommandLineProtocol.version, clientVersion: String = CommandLineToolVersion.current) {
        self.protocolVersion = protocolVersion
        self.clientVersion = clientVersion
    }
}

/// The host's answer to ``Hello``. Sent even when the versions differ, so the
/// client can tell an outdated host from an absent one.
public struct Welcome: Codable, Sendable, Hashable {
    public let protocolVersion: Int
    public let hostVersion: String
    public let hostKind: HostKind
    public let processIdentifier: Int32

    public init(protocolVersion: Int = CommandLineProtocol.version, hostVersion: String = CommandLineToolVersion.current, hostKind: HostKind, processIdentifier: Int32) {
        self.protocolVersion = protocolVersion
        self.hostVersion = hostVersion
        self.hostKind = hostKind
        self.processIdentifier = processIdentifier
    }
}

public enum ClientMessage: Codable, Sendable, Hashable {
    case hello(Hello)
    case command(requestIdentifier: UUID, command: Command)
    case cancel(requestIdentifier: UUID)
}

public enum HostMessage: Codable, Sendable, Hashable {
    case welcome(Welcome)
    case progress(requestIdentifier: UUID, progress: CommandProgress)
    case completed(requestIdentifier: UUID, result: CommandResult)
    case failed(requestIdentifier: UUID, failure: CommandFailure)
}
