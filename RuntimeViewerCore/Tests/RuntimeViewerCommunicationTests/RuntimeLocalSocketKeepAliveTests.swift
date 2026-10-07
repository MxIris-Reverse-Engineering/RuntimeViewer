import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// That a connected socket is set up to notice a peer that stops answering.
///
/// The failure this guards against does not look like a failure. A peer that
/// closes properly sends a FIN and `recv` returns 0; a peer that *vanishes* —
/// a powered-off virtual machine, a link that goes away — sends nothing, and
/// without keepalive the kernel holds the half-open connection indefinitely.
/// `recv` blocks forever, no state change is published, and the engine stays in
/// the list looking connected.
///
/// Measured before the fix: with the guest powered off, the Mac still held
/// `169.254.46.29:60121->169.254.21.214:49351 (ESTABLISHED)` to a machine that
/// no longer existed, and the injected engine was still listed while the
/// Bonjour engine beside it had correctly gone.
@Suite("Local socket keepalive")
struct RuntimeLocalSocketKeepAliveTests {
    /// A connected pair of TCP sockets on the loopback interface.
    ///
    /// Not `socketpair(2)`: that gives `AF_UNIX`, where the `IPPROTO_TCP`
    /// options under test do not exist. The point is to read back what was set
    /// on a real TCP socket.
    private struct ConnectedPair: ~Copyable {
        let clientSocket: Int32
        let acceptedSocket: Int32
        private let listeningSocket: Int32

        init() throws {
            // Locals throughout, assigned to the stored properties at the end:
            // the pointer closures below would otherwise capture a `self` whose
            // constants are not initialised yet.
            let listening = socket(AF_INET, SOCK_STREAM, 0)
            try #require(listening >= 0)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0 // any free port
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(listening, 1) == 0)

            var boundAddress = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &boundAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listening, $0, &boundLength)
                }
            }
            try #require(named == 0)

            let client = socket(AF_INET, SOCK_STREAM, 0)
            try #require(client >= 0)
            let connected = withUnsafePointer(to: &boundAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)

            let accepted = accept(listening, nil, nil)
            try #require(accepted >= 0)

            listeningSocket = listening
            clientSocket = client
            acceptedSocket = accepted
        }

        deinit {
            close(acceptedSocket)
            close(clientSocket)
            close(listeningSocket)
        }
    }

    private static func integerOption(_ option: Int32, level: Int32, on socketFD: Int32) -> Int32? {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socketFD, level, option, &value, &length) == 0 else { return nil }
        return value
    }

    @Test("A configured socket has keepalive on, not the system's two-hour default")
    func keepAliveIsEnabledAndProbesSoon() throws {
        let pair = try ConnectedPair()
        RuntimeLocalSocketConnection.configureSocketOptions(pair.clientSocket)

        #expect(Self.integerOption(SO_KEEPALIVE, level: SOL_SOCKET, on: pair.clientSocket) != 0)

        // The idle time is the whole point: the default is 7200 seconds, which
        // for this purpose is the same as never.
        let idle = try #require(Self.integerOption(TCP_KEEPALIVE, level: IPPROTO_TCP, on: pair.clientSocket))
        #expect(idle == RuntimeLocalSocketConnection.keepAliveIdleSeconds)
        #expect(idle < 60)

        let interval = try #require(Self.integerOption(TCP_KEEPINTVL, level: IPPROTO_TCP, on: pair.clientSocket))
        #expect(interval == RuntimeLocalSocketConnection.keepAliveIntervalSeconds)

        let probeCount = try #require(Self.integerOption(TCP_KEEPCNT, level: IPPROTO_TCP, on: pair.clientSocket))
        #expect(probeCount == RuntimeLocalSocketConnection.keepAliveProbeCount)
    }

    /// The whole budget has to stay small enough that a user notices the engine
    /// go away rather than wondering why it never answers.
    @Test("A vanished peer is declared dead inside half a minute")
    func deadPeerBudgetIsShort() {
        let budget = RuntimeLocalSocketConnection.keepAliveIdleSeconds
            + RuntimeLocalSocketConnection.keepAliveIntervalSeconds
            * RuntimeLocalSocketConnection.keepAliveProbeCount
        #expect(budget <= 30)
    }

    /// Latency still matters as much as it did; this is the option that was
    /// already there, and moving it into the shared helper must not drop it.
    @Test("The shared helper still disables Nagle")
    func nagleStaysDisabled() throws {
        let pair = try ConnectedPair()
        RuntimeLocalSocketConnection.configureSocketOptions(pair.acceptedSocket)
        #expect(Self.integerOption(TCP_NODELAY, level: IPPROTO_TCP, on: pair.acceptedSocket) != 0)
    }

    /// A send to a peer that has reset the connection must come back as
    /// `EPIPE`, not as `SIGPIPE`, whose default action ends the process — the
    /// host app on one end, and on the other whatever process the payload was
    /// injected into. A peer resetting is routine here: a detach while a large
    /// reply is still being read, a device process killed, a keepalive giving
    /// up. Nothing ignores the signal process-wide, and an injected payload has
    /// no business changing its host's signal dispositions, so it has to be the
    /// socket's own option, on the dialling end and the accepting end alike.
    @Test("A configured socket fails a send to a reset peer instead of raising SIGPIPE")
    func sendToResetPeerDoesNotRaiseSignal() throws {
        let pair = try ConnectedPair()
        RuntimeLocalSocketConnection.configureSocketOptions(pair.clientSocket)
        RuntimeLocalSocketConnection.configureSocketOptions(pair.acceptedSocket)

        let dialledEndOption = try #require(Self.integerOption(SO_NOSIGPIPE, level: SOL_SOCKET, on: pair.clientSocket))
        let acceptedEndOption = try #require(Self.integerOption(SO_NOSIGPIPE, level: SOL_SOCKET, on: pair.acceptedSocket))
        #expect(dialledEndOption != 0)
        #expect(acceptedEndOption != 0)
    }
}
