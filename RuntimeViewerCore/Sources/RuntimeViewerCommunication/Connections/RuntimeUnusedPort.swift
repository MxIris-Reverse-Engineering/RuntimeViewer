// `public import` because the public `Failure` conforms to `LocalizedError`,
// and this module builds with `InternalImportsByDefault`.
public import Foundation

/// Asks the kernel for a port nothing is listening on.
///
/// `RuntimeLocalSocketPortDiscovery` answers a different question: it derives a
/// port both ends can compute from an identifier they share, which is what lets
/// a payload on this machine find a listener without any discovery at all. That
/// does not work for a payload on a device, because the host has to be listening
/// *before* the payload exists and so cannot wait to be told a number — it has
/// to choose one and send it over.
public enum RuntimeUnusedPort {
    /// A port that was free a moment ago.
    ///
    /// Binds port 0, reads back what the kernel assigned, and closes. **The
    /// answer is advisory**: nothing holds the port between this returning and
    /// the caller binding it, so another process on this machine can take it in
    /// between. That window is accepted rather than engineered away — the only
    /// alternative is handing the bound socket itself to the connection layer,
    /// which would mean a second way to construct every connection in it, and
    /// losing the race fails loudly at the caller's own `bind` rather than
    /// silently.
    ///
    /// The kernel picks from the ephemeral range, so the result is well clear of
    /// anything with a registered service on it.
    public static func find() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.couldNotAsk(errorNumber: errno)
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // Port 0 is the request: "assign me one".
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw Failure.couldNotAsk(errorNumber: errno)
        }

        var assignedAddress = sockaddr_in()
        var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assignedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &assignedLength)
            }
        }
        guard nameResult == 0 else {
            throw Failure.couldNotAsk(errorNumber: errno)
        }

        let port = UInt16(bigEndian: assignedAddress.sin_port)
        // Zero would mean the kernel assigned nothing, which it does not do
        // after a successful bind — but passing it on would produce a rendezvous
        // naming port 0, and a payload dialling that fails with an error about
        // the address rather than about this.
        guard port != 0 else { throw Failure.kernelAssignedNoPort }
        return port
    }

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case couldNotAsk(errorNumber: Int32)
        case kernelAssignedNoPort

        public var description: String {
            switch self {
            case .couldNotAsk(let errorNumber):
                return "RuntimeUnusedPort.couldNotAsk: could not ask the kernel for a free port - errno=\(errorNumber): \(String(cString: strerror(errorNumber)))"
            case .kernelAssignedNoPort:
                return "RuntimeUnusedPort.kernelAssignedNoPort: the kernel reported port 0 after a successful bind"
            }
        }

        public var errorDescription: String? { description }
    }
}
