import Testing
import Foundation
#if canImport(Network)
import Network
#endif
@testable import RuntimeViewerCommunication

/// `RuntimeConnectionError.isLostConnection(_:)`: what each transport throws
/// at a request whose connection went away, told apart from a peer's answer,
/// a request that timed out and a cancellation. The errors of most
/// transports are internal to this module, which is why callers need the
/// question asked here. End to end, over a real XPC service and a real
/// socket, the Find corpus coordinator's `FindCorpusCoordinatorLostConnectionTests`
/// exercise it.
@Suite("RuntimeConnectionError.isLostConnection")
struct RuntimeConnectionLostConnectionTests {
    @Test("every transport's lost connection is recognised")
    func lostConnectionsAreRecognised() {
        var lostConnectionErrors: [any Swift.Error] = [
            RuntimeConnectionError.peerClosed,
            RuntimeConnectionError.notConnected,
            RuntimeConnectionError.socketError("Connection reset by peer"),
            RuntimeConnectionError.networkError("Connection failed"),
            RuntimeConnectionError.xpcError("Connection invalid"),
            RuntimeConnectionError.timeout,
            RuntimeMessageChannelError.notConnected,
            RuntimeNetworkError.notConnected,
            RuntimeNetworkError.receiveFailed,
            RuntimeLocalSocketError.notConnected,
            RuntimeLocalSocketError.receiveFailed,
            RuntimeLocalSocketError.sendFailed(errno: EPIPE),
            RuntimeStdioError.notConnected,
            RuntimeStdioError.receiveFailed,
        ]
        #if canImport(Network)
        lostConnectionErrors.append(NWError.posix(.ECONNRESET))
        #endif
        #if os(macOS)
        lostConnectionErrors.append(RuntimeXPCServiceConnectionError.serviceExited)
        lostConnectionErrors.append(RuntimeXPCServiceConnectionError.connectionInvalid)
        lostConnectionErrors.append(RuntimeXPCServiceConnectionError.noClientAttached)
        #endif
        for error in lostConnectionErrors {
            #expect(RuntimeConnectionError.isLostConnection(error), "not recognised as a lost connection: \(error)")
        }
    }

    @Test("an answer, a timed-out request and a cancellation are not lost connections")
    func otherFailuresAreNotLostConnections() {
        var otherErrors: [any Swift.Error] = [
            RuntimeNetworkRequestError(message: RuntimeNetworkRequestError.unknownCommandMessagePrefix + "com.example.command"),
            RuntimeNetworkRequestError(message: "The handler threw."),
            RuntimeMessageChannelError.requestTimeout,
            RuntimeMessageChannelError.receiveFailed,
            RuntimeConnectionError.listenerWaiting,
            RuntimeConnectionError.unknown("Something else"),
            RuntimeNetworkError.invalidPort,
            RuntimeLocalSocketError.connectFailed(errno: ECONNREFUSED, host: "127.0.0.1", port: 1),
            RuntimeLocalSocketError.invalidHostAddress("not-an-address"),
            CancellationError(),
            DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Not JSON")),
        ]
        #if os(macOS)
        otherErrors.append(RuntimeXPCServiceConnectionError.remoteFailure("The handler threw."))
        #endif
        for error in otherErrors {
            #expect(!RuntimeConnectionError.isLostConnection(error), "taken for a lost connection: \(error)")
        }
    }
}
