import Foundation

/// The addresses this machine has on a named network interface.
///
/// Exists to answer one question: a connection to a device reports which
/// interface it runs over, but — measured — reports its own address on that
/// interface as IPv6 link-local, while an injected payload dials IPv4. The
/// interface is the part worth keeping, because it was observed rather than
/// guessed; only the address family has to be converted.
enum RuntimeInterfaceAddresses {
    /// The IPv4 address assigned to `interfaceName`, or `nil` when it has none.
    ///
    /// A routable address wins over a self-assigned `169.254.0.0/16` one when
    /// an interface carries both — but a link-local address is still returned
    /// when it is all there is, which is the ordinary case for a link with no
    /// DHCP on it: both ends self-assign, and they can reach each other.
    static func ipv4Address(ofInterfaceNamed interfaceName: String) -> String? {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let interfaceList else { return nil }
        defer { freeifaddrs(interfaceList) }

        var selfAssignedAddress: String?

        for interface in sequence(first: interfaceList, next: \.pointee.ifa_next) {
            guard let nameBytes = interface.pointee.ifa_name,
                  String(cString: nameBytes) == interfaceName,
                  let addressBytes = interface.pointee.ifa_addr,
                  addressBytes.pointee.sa_family == sa_family_t(AF_INET),
                  let address = dottedQuad(of: addressBytes)
            else { continue }

            if isSelfAssigned(address) {
                selfAssignedAddress = selfAssignedAddress ?? address
            } else {
                return address
            }
        }
        return selfAssignedAddress
    }

    /// `169.254.0.0/16`, which a host assigns itself when nothing hands out
    /// addresses on the link.
    private static func isSelfAssigned(_ address: String) -> Bool {
        address.hasPrefix("169.254.")
    }

    private static func dottedQuad(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var internetAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &internetAddress, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }
}
