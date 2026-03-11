import Testing
@testable import RuntimeViewerMCPBridge

@Suite("MCPServerState")
struct MCPServerStateTests {
    // MARK: - isRunning

    @Test("disabled state is not running")
    func disabledIsNotRunning() {
        let state = MCPServerState.disabled
        #expect(!state.isRunning)
    }

    @Test("stopped state is not running")
    func stoppedIsNotRunning() {
        let state = MCPServerState.stopped
        #expect(!state.isRunning)
    }

    @Test("running state is running")
    func runningIsRunning() {
        let state = MCPServerState.running(port: 8080)
        #expect(state.isRunning)
    }

    // MARK: - port

    @Test("disabled state has no port")
    func disabledHasNoPort() {
        let state = MCPServerState.disabled
        #expect(state.port == nil)
    }

    @Test("stopped state has no port")
    func stoppedHasNoPort() {
        let state = MCPServerState.stopped
        #expect(state.port == nil)
    }

    @Test("running state returns its port")
    func runningReturnsPort() {
        let state = MCPServerState.running(port: 9090)
        #expect(state.port == 9090)
    }

    @Test("running state port matches provided value", arguments: [
        UInt16(0), 80, 443, 8080, 65535,
    ] as [UInt16])
    func runningPortMatchesValue(port: UInt16) {
        let state = MCPServerState.running(port: port)
        #expect(state.port == port)
    }

    // MARK: - Equatable

    @Test("same states are equal")
    func sameStatesAreEqual() {
        #expect(MCPServerState.disabled == .disabled)
        #expect(MCPServerState.stopped == .stopped)
        #expect(MCPServerState.running(port: 8080) == .running(port: 8080))
    }

    @Test("different states are not equal")
    func differentStatesAreNotEqual() {
        #expect(MCPServerState.disabled != .stopped)
        #expect(MCPServerState.stopped != .running(port: 8080))
        #expect(MCPServerState.running(port: 8080) != .running(port: 9090))
    }
}
