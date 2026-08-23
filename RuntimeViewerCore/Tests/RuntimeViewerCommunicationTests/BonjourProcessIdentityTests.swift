import Testing
import Foundation
import Network
@testable import RuntimeViewerCommunication

/// Covers the identity a Bonjour peer advertises once several *processes* on a
/// single device can each carry a server payload — the shape injecting an iOS
/// Simulator produces.
///
/// Before this, an iOS peer advertised one service name per device and the host
/// keyed everything by that name, so the second injected process on a device was
/// written off as a duplicate of the first and never connected at all.
@Suite("Bonjour process identity")
struct BonjourProcessIdentityTests {
    private static func endpoint(
        name: String,
        deviceID: String? = nil,
        processName: String? = nil,
        processIdentifier: String? = nil
    ) -> RuntimeNetworkEndpoint {
        RuntimeNetworkEndpoint(
            name: name,
            instanceID: nil,
            hostName: nil,
            deviceMetadata: nil,
            deviceID: deviceID,
            processName: processName,
            processIdentifier: processIdentifier,
            endpoint: .service(name: name, type: RuntimeNetworkBonjour.type, domain: "local.", interface: nil)
        )
    }

    @Test("TXT record keys")
    func txtRecordKeys() {
        #expect(RuntimeNetworkBonjour.deviceIDKey == "rv-device-id")
        #expect(RuntimeNetworkBonjour.processNameKey == "rv-proc-name")
        #expect(RuntimeNetworkBonjour.processIdentifierKey == "rv-proc-pid")
    }

    @Test("Unique key combines device ID and pid")
    func uniqueKeyFromDeviceAndProcess() {
        let discovered = Self.endpoint(
            name: "service-name",
            deviceID: "DEVICE-A",
            processName: "SpringBoard",
            processIdentifier: "42475"
        )
        #expect(discovered.uniqueKey == "DEVICE-A-42475")
    }

    /// The regression this whole change exists for: two processes inside one
    /// simulator advertise the same device ID, and must still be told apart.
    @Test("Two processes on one device get distinct keys")
    func twoProcessesOnOneDeviceAreDistinct() {
        let first = Self.endpoint(name: "svc-1", deviceID: "DEVICE-A", processName: "gamecontrollerd", processIdentifier: "58675")
        let second = Self.endpoint(name: "svc-2", deviceID: "DEVICE-A", processName: "nanoappregistryd", processIdentifier: "3964")

        #expect(first.uniqueKey != second.uniqueKey)
    }

    /// A peer predating the TXT keys publishes neither, and must keep behaving
    /// exactly as it did when the service name was the only key there was.
    @Test("Legacy peers fall back to the service name", arguments: [
        (deviceID: String?.none, processIdentifier: String?.some("42475")),
        (deviceID: String?.some("DEVICE-A"), processIdentifier: String?.none),
        (deviceID: String?.none, processIdentifier: String?.none),
    ])
    func legacyPeersFallBackToName(deviceID: String?, processIdentifier: String?) {
        let discovered = Self.endpoint(name: "iPhone 17 Pro", deviceID: deviceID, processIdentifier: processIdentifier)
        #expect(discovered.uniqueKey == "iPhone 17 Pro")
    }

    @Test("Local service name is process-level and stable")
    func localServiceName() {
        let serviceName = RuntimeNetworkBonjour.localServiceName
        #expect(!serviceName.isEmpty)
        #expect(serviceName.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier)"))
        #expect(serviceName == RuntimeNetworkBonjour.localServiceName)
    }

    @Test("Local device ID is non-empty and stable")
    func localDeviceID() {
        let deviceID = RuntimeNetworkBonjour.localDeviceID
        #expect(!deviceID.isEmpty)
        #expect(RuntimeNetworkBonjour.localDeviceID == deviceID)
    }

    /// `RuntimeSource.identifier` keys notifications and the engine-mirroring
    /// registry. A Bonjour client's *name* is now the peer's process display
    /// name, which two processes can share, so the identifier has to come from
    /// the process-level key instead.
    @Test("Bonjour client source identifier ignores the display name")
    func sourceIdentifierIgnoresDisplayName() {
        let first = RuntimeSource.bonjour(name: "SpringBoard", identifier: .init(rawValue: "DEVICE-A-1"), role: .client)
        let second = RuntimeSource.bonjour(name: "SpringBoard", identifier: .init(rawValue: "DEVICE-A-2"), role: .client)

        #expect(first.identifier != second.identifier)
        #expect(first.identifier == "bonjour.DEVICE-A-1")
    }
}
