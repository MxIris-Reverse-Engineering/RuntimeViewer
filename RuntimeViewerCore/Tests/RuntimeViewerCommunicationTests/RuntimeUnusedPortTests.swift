import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// Picking a port for a payload that has not been injected yet.
///
/// The answer is advisory by construction — nothing holds the port between this
/// returning and the caller binding it — so what is pinned here is that it is
/// *usable*, not that it is reserved.
@Suite("RuntimeUnusedPort", .serialized)
struct RuntimeUnusedPortTests {
    @Test("Answers a port in the ephemeral range")
    func answersAnEphemeralPort() throws {
        let port = try RuntimeUnusedPort.find()
        // Not an exact range check: which range the kernel draws from is its
        // business, and pinning macOS's current one would make this a test of
        // the operating system. Zero is the only answer that is wrong by
        // definition, because a rendezvous naming port 0 cannot be dialled.
        #expect(port != 0)
    }

    /// What it is for: the caller binds it next. A throw here fails the test,
    /// which is the whole assertion.
    @Test("The port it answers can then be bound")
    func theAnswerIsBindable() async throws {
        let port = try RuntimeUnusedPort.find()

        let connection = RuntimeLocalSocketServerConnection(
            bindAddress: RuntimeLocalSocketAddress.loopback,
            port: port,
        )
        defer { connection.stop() }
        try await connection.start()
    }

    /// Consecutive calls do not hand out the same port, so two injections in
    /// flight at once do not collide. The kernel rotates through the ephemeral
    /// range, which is what makes this true — asserted rather than assumed,
    /// because the whole scheme rests on it.
    @Test("Consecutive calls do not all answer the same port")
    func consecutiveCallsSpreadOut() throws {
        var ports: Set<UInt16> = []
        for _ in 0 ..< 8 {
            ports.insert(try RuntimeUnusedPort.find())
        }
        #expect(ports.count > 1)
    }
}
