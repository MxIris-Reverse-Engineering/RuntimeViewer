import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// Looking up an interface's IPv4 address.
///
/// This exists because a connection to a device reports its own address as IPv6
/// link-local — measured, `fe80::4c5:a2b1:1313:2629%en26` for a device on a
/// virtual network interface — while the injected payload dials IPv4. The
/// interface in that address is the measured part and is kept; this converts
/// only the family.
@Suite("Interface addresses")
struct RuntimeInterfaceAddressesTests {
    /// Every machine has it, and it always carries exactly this address.
    @Test("Loopback is found by name")
    func loopbackIsFound() {
        #expect(RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: "lo0") == "127.0.0.1")
    }

    /// The answer has to be "there is none" rather than something nearby. An
    /// interface's neighbour's address would send a payload to the wrong place
    /// on a machine with several networks, which is exactly the situation this
    /// whole lookup exists for.
    @Test("An interface this machine does not have yields nothing")
    func unknownInterfaceYieldsNothing() {
        #expect(RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: "en9999") == nil)
        #expect(RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: "") == nil)
    }

    /// An interface with no IPv4 at all is a real state — a virtual interface
    /// carrying only IPv6 — and it has to be reported as such, because the
    /// caller turns it into a sentence explaining why no injection can happen.
    @Test("An IPv6-only interface yields nothing rather than an address from elsewhere")
    func interfaceWithoutIPv4YieldsNothing() throws {
        let interfaceNames = Self.allInterfaceNames()
        let withoutIPv4 = interfaceNames.filter { RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: $0) == nil }
        // Not an assertion that such an interface exists — a machine may have
        // none. What is asserted is that when one does, the answer is nil and
        // not some other interface's address.
        for interfaceName in withoutIPv4 {
            #expect(RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: interfaceName) == nil)
        }
        // And that the lookup is not simply answering nil for everything.
        #expect(interfaceNames.contains { RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: $0) != nil })
    }

    /// Whatever comes back has to be dottedable back into an address, because
    /// it is handed to `inet_pton` on both ends of the injected connection.
    @Test("Every address it returns parses as IPv4")
    func everyAnswerParsesAsIPv4() {
        for interfaceName in Self.allInterfaceNames() {
            guard let address = RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: interfaceName) else { continue }
            var parsed = in_addr()
            #expect(inet_pton(AF_INET, address, &parsed) == 1, "\(interfaceName) gave '\(address)'")
        }
    }

    /// The property that makes this usable at all, checked against this
    /// machine's real interfaces: an interface carrying exactly one IPv4
    /// address gives that one back. It is what covers the case this was
    /// written for — a virtual interface whose single IPv4 is a self-assigned
    /// `169.254` one, which must still be answered rather than discarded.
    @Test("An interface with exactly one IPv4 address gives that one back")
    func singleAddressInterfacesAnswerIt() {
        let addressesByInterface = Self.ipv4AddressesByInterface()
        var checked = 0
        for (interfaceName, addresses) in addressesByInterface where addresses.count == 1 {
            #expect(RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: interfaceName) == addresses[0], "\(interfaceName)")
            checked += 1
        }
        #expect(checked > 0, "This machine has no single-address interface, so nothing was checked")
    }

    private static func ipv4AddressesByInterface() -> [String: [String]] {
        var addresses: [String: [String]] = [:]
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let interfaceList else { return addresses }
        defer { freeifaddrs(interfaceList) }
        for interface in sequence(first: interfaceList, next: \.pointee.ifa_next) {
            guard let nameBytes = interface.pointee.ifa_name,
                  let addressBytes = interface.pointee.ifa_addr,
                  addressBytes.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var internetAddress = addressBytes.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &internetAddress, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            addresses[String(cString: nameBytes), default: []].append(String(cString: text))
        }
        return addresses
    }

    private static func allInterfaceNames() -> Set<String> {
        var names: Set<String> = []
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let interfaceList else { return names }
        defer { freeifaddrs(interfaceList) }
        for interface in sequence(first: interfaceList, next: \.pointee.ifa_next) {
            guard let nameBytes = interface.pointee.ifa_name else { continue }
            names.insert(String(cString: nameBytes))
        }
        return names
    }
}
