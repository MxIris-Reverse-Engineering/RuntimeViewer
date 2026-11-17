import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// A local socket connection's descriptor is used by three threads at once —
/// one blocked in `recv`, one sending, and whichever stops the connection —
/// and `stop()` used to close it while the others could still be about to use
/// its number. Once closed, the number goes to the next file the process
/// opens, so a late `send` writes the connection's bytes into that file, and a
/// late `recv` reads that file's data. The codebase audit's CA.17.
@Suite("Local socket descriptor lifetime", .serialized)
struct RuntimeLocalSocketDescriptorLifetimeTests {
    /// Stops the connection between two `send`s of one message — the message
    /// is larger than what one `send` takes — and holds its `close` open until
    /// the next call, so a send that read the descriptor before `stop()`
    /// forgot it shows up as a call on a closed descriptor.
    @Test("Stopping a connection in the middle of a send never lets the send reach the closed descriptor")
    func stopDuringSendDoesNotUseClosedDescriptor() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[1]) }
        var noSignalOnBrokenPipe: Int32 = 1
        setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignalOnBrokenPipe, socklen_t(MemoryLayout<Int32>.size))

        let systemCalls = ScriptedSocketSystemCalls()
        systemCalls.holdFirstCloseUntilNextCall()
        let connection = RuntimeLocalSocketConnection(socketFD: descriptors[0], systemCalls: systemCalls)
        systemCalls.onFirstSend = { [weak connection] stepIn in
            DispatchQueue.global().async {
                connection?.stop()
                stepIn.signal()
            }
        }
        try connection.start()

        let requestData = try RuntimeRequestData(request: EchoRequest(message: String(repeating: "x", count: 4096)))
        _ = try? await connection.send(requestData: requestData)

        #expect(systemCalls.callsAfterClose.isEmpty, "Calls made on the descriptor after it was closed: \(systemCalls.callsAfterClose)")
    }
}
