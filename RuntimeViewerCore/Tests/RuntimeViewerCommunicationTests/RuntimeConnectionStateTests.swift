import Testing
import Foundation
import RuntimeViewerCommunication

@Suite("RuntimeConnectionState")
struct RuntimeConnectionStateTests {
    // MARK: - isConnected

    @Test("connecting is not connected")
    func connectingNotConnected() {
        #expect(RuntimeConnectionState.connecting.isConnected == false)
    }

    @Test("connected is connected")
    func connectedIsConnected() {
        #expect(RuntimeConnectionState.connected.isConnected == true)
    }

    @Test("disconnected is not connected")
    func disconnectedNotConnected() {
        #expect(RuntimeConnectionState.disconnected(error: nil).isConnected == false)
    }

    @Test("disconnected with error is not connected")
    func disconnectedWithErrorNotConnected() {
        #expect(RuntimeConnectionState.disconnected(error: .timeout).isConnected == false)
    }

    // MARK: - isConnecting

    @Test("connecting is connecting")
    func connectingIsConnecting() {
        #expect(RuntimeConnectionState.connecting.isConnecting == true)
    }

    @Test("connected is not connecting")
    func connectedNotConnecting() {
        #expect(RuntimeConnectionState.connected.isConnecting == false)
    }

    @Test("disconnected is not connecting")
    func disconnectedNotConnecting() {
        #expect(RuntimeConnectionState.disconnected(error: nil).isConnecting == false)
    }

    // MARK: - isDisconnected

    @Test("connecting is not disconnected")
    func connectingNotDisconnected() {
        #expect(RuntimeConnectionState.connecting.isDisconnected == false)
    }

    @Test("connected is not disconnected")
    func connectedNotDisconnected() {
        #expect(RuntimeConnectionState.connected.isDisconnected == false)
    }

    @Test("disconnected is disconnected")
    func disconnectedIsDisconnected() {
        #expect(RuntimeConnectionState.disconnected(error: nil).isDisconnected == true)
    }

    @Test("disconnected with error is disconnected")
    func disconnectedWithErrorIsDisconnected() {
        #expect(RuntimeConnectionState.disconnected(error: .peerClosed).isDisconnected == true)
    }

    // MARK: - Equatable

    @Test("same states are equal")
    func sameStatesEqual() {
        #expect(RuntimeConnectionState.connecting == .connecting)
        #expect(RuntimeConnectionState.connected == .connected)
        #expect(RuntimeConnectionState.disconnected(error: nil) == .disconnected(error: nil))
        #expect(RuntimeConnectionState.disconnected(error: .timeout) == .disconnected(error: .timeout))
    }

    @Test("different states are not equal")
    func differentStatesNotEqual() {
        #expect(RuntimeConnectionState.connecting != .connected)
        #expect(RuntimeConnectionState.connected != .disconnected(error: nil))
        #expect(RuntimeConnectionState.disconnected(error: .timeout) != .disconnected(error: .peerClosed))
    }
}

@Suite("RuntimeConnectionError")
struct RuntimeConnectionErrorTests {
    @Test("socketError has descriptive message")
    func socketError() {
        let error = RuntimeConnectionError.socketError("Connection refused")
        #expect(error.errorDescription!.contains("Socket error"))
        #expect(error.errorDescription!.contains("Connection refused"))
    }

    @Test("networkError has descriptive message")
    func networkError() {
        let error = RuntimeConnectionError.networkError("DNS resolution failed")
        #expect(error.errorDescription!.contains("Network error"))
        #expect(error.errorDescription!.contains("DNS resolution failed"))
    }

    @Test("xpcError has descriptive message")
    func xpcError() {
        let error = RuntimeConnectionError.xpcError("Service not found")
        #expect(error.errorDescription!.contains("XPC error"))
        #expect(error.errorDescription!.contains("Service not found"))
    }

    @Test("timeout has descriptive message")
    func timeout() {
        let error = RuntimeConnectionError.timeout
        #expect(error.errorDescription!.contains("timed out"))
    }

    @Test("peerClosed has descriptive message")
    func peerClosed() {
        let error = RuntimeConnectionError.peerClosed
        #expect(error.errorDescription!.contains("closed by peer"))
    }

    @Test("unknown has descriptive message")
    func unknown() {
        let error = RuntimeConnectionError.unknown("Something unexpected")
        #expect(error.errorDescription!.contains("Unknown error"))
        #expect(error.errorDescription!.contains("Something unexpected"))
    }

    @Test("notConnected has descriptive message")
    func notConnected() {
        let error = RuntimeConnectionError.notConnected
        #expect(error.errorDescription!.contains("Not connected"))
    }

    @Test("all errors produce non-nil errorDescription", arguments: [
        RuntimeConnectionError.socketError("msg"),
        .networkError("msg"),
        .xpcError("msg"),
        .timeout,
        .peerClosed,
        .unknown("msg"),
        .notConnected,
    ])
    func allErrorsHaveDescription(error: RuntimeConnectionError) {
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    // MARK: - Equatable

    @Test("same errors are equal")
    func sameErrorsEqual() {
        #expect(RuntimeConnectionError.timeout == .timeout)
        #expect(RuntimeConnectionError.peerClosed == .peerClosed)
        #expect(RuntimeConnectionError.notConnected == .notConnected)
        #expect(RuntimeConnectionError.socketError("msg") == .socketError("msg"))
    }

    @Test("different errors are not equal")
    func differentErrorsNotEqual() {
        #expect(RuntimeConnectionError.timeout != .peerClosed)
        #expect(RuntimeConnectionError.socketError("a") != .socketError("b"))
        #expect(RuntimeConnectionError.socketError("msg") != .networkError("msg"))
    }
}

@Suite("RuntimeRequestResponse")
struct RuntimeRequestResponseTests {
    @Test("RuntimeViewerMachServiceName is not empty")
    func machServiceName() {
        #expect(!RuntimeViewerMachServiceName.isEmpty)
    }

    @Test("VoidResponse can be created")
    func voidResponse() {
        let response = VoidResponse()
        let empty = VoidResponse.empty
        // Just verifying they can be created
        _ = response
        _ = empty
    }

    @Test("VoidResponse is Codable")
    func voidResponseCodable() throws {
        let original = VoidResponse.empty
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoidResponse.self, from: data)
        _ = decoded
    }
}
