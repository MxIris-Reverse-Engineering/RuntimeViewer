import Foundation
import FoundationToolbox
import Combine

/// Client-side stdio connection for sending requests to a child process.
///
/// Use this when your process launches another process and wants to communicate with it.
///
/// ## Usage
///
/// ```swift
/// let process = Process()
/// process.executableURL = URL(fileURLWithPath: "/path/to/server")
///
/// let stdinPipe = Pipe()
/// let stdoutPipe = Pipe()
/// process.standardInput = stdinPipe
/// process.standardOutput = stdoutPipe
///
/// try process.run()
///
/// let client = try RuntimeStdioClientConnection(
///     inputHandle: stdoutPipe.fileHandleForReading,
///     outputHandle: stdinPipe.fileHandleForWriting
/// )
///
/// // Send typed request
/// let response = try await client.sendMessage(request: MyRequest(value: "hello"))
///
/// // Or send by name
/// let result: String = try await client.sendMessage(name: "echo", request: "hello")
/// ```
final class RuntimeStdioClientConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

    private var _underlyingConnection: RuntimeStdioConnection?

    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    /// Bridges underlying connection state into `stateSubject`; kept alive for
    /// the connection's lifetime so subscribers still observe the final
    /// `.disconnected` emitted while stopping.
    private var underlyingStateCancellable: AnyCancellable?

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    /// Creates a client connection with the specified file handles.
    ///
    /// - Parameters:
    ///   - inputHandle: File handle to read responses from (typically the child's stdout).
    ///   - outputHandle: File handle to write requests to (typically the child's stdin).
    /// - Throws: `RuntimeStdioError` if connection cannot be started.
    init(inputHandle: FileHandle, outputHandle: FileHandle) throws {
        let connection = RuntimeStdioConnection(inputHandle: inputHandle, outputHandle: outputHandle)
        self._underlyingConnection = connection
        self.underlyingStateCancellable = connection.statePublisher
            .sink { [weak self] connectionState in
                self?.stateSubject.send(connectionState)
            }
        try connection.start()
    }
}
