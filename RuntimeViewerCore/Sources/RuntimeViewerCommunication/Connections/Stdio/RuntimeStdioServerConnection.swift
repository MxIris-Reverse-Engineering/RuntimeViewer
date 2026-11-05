import Foundation
import FoundationToolbox
import Combine

/// Server-side stdio connection for handling requests from a parent process.
///
/// Use this when your process is launched by another process and should respond to its requests.
///
/// ## Usage
///
/// ```swift
/// let server = try RuntimeStdioServerConnection(
///     inputHandle: .standardInput,
///     outputHandle: .standardOutput
/// )
///
/// // Register handler for typed requests
/// server.setMessageHandler(requestType: MyRequest.self) { request in
///     return MyResponse(result: "Received: \(request.value)")
/// }
///
/// // Register handler by name
/// server.setMessageHandler(name: "echo") { (input: String) -> String in
///     return "Echo: \(input)"
/// }
///
/// // Keep process alive
/// RunLoop.main.run()
/// ```
final class RuntimeStdioServerConnection: RuntimeForwardingConnection, @unchecked Sendable {
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

    /// Creates a server connection with the specified file handles.
    ///
    /// - Parameters:
    ///   - inputHandle: File handle to read requests from (typically `.standardInput`).
    ///   - outputHandle: File handle to write responses to (typically `.standardOutput`).
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
