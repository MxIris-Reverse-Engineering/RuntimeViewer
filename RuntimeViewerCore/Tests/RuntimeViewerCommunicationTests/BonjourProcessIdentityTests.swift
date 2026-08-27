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

    @Test("Service name is composed of the host and process names only")
    func serviceNameComposition() {
        #expect(
            RuntimeNetworkBonjour.serviceName(hostName: "JH's iPhone", processName: "mobiletimerd")
                == "JH's iPhone (mobiletimerd)"
        )
    }

    /// The service name doubles as a *persistent key* on any host predating the
    /// TXT keys: it lands in `NSOutlineView`'s autosave names by way of
    /// `RuntimeSource.description`. Carrying the pid there gave such a host a
    /// fresh set of those keys on every relaunch of this process, accumulating
    /// in its `UserDefaults` with nothing to ever clean them up — and showed the
    /// user a raw identifier where a device name belonged.
    @Test("Local service name carries no process identifier")
    func localServiceNameCarriesNoProcessIdentifier() {
        let serviceName = RuntimeNetworkBonjour.localServiceName
        #expect(!serviceName.isEmpty)
        #expect(!serviceName.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier)"))
        #expect(
            serviceName == RuntimeNetworkBonjour.serviceName(
                hostName: RuntimeNetworkBonjour.localHostName,
                processName: RuntimeNetworkBonjour.localProcessName
            )
        )
    }

    @Test("Local service name is stable across reads")
    func localServiceNameIsStable() {
        #expect(RuntimeNetworkBonjour.localServiceName == RuntimeNetworkBonjour.localServiceName)
    }

    /// What a peer actually advertises must come from ``resolvedHostName()``,
    /// not from the non-blocking ``localHostName``. The difference only shows
    /// on an iOS device: `localHostName` has no way to reach the user-assigned
    /// name there and falls back to a model name, so an advertisement built
    /// from it reads `"iPhone (RuntimeViewer)"`. A host predating the TXT keys
    /// puts that string in its window title *and* its sidebar autosave keys, so
    /// the downgrade outlives the session that caused it.
    ///
    /// Honest about its own reach: on macOS both names come from
    /// `SCDynamicStoreCopyComputerName`, so this cannot tell them apart at
    /// runtime here. What it does hold is the composition — a body that drifts
    /// back to `localHostName` still passes on macOS but fails the moment this
    /// suite runs on a device.
    @Test("Resolved service name is composed from the resolved host name")
    func resolvedServiceNameUsesResolvedHostName() async {
        let expected = RuntimeNetworkBonjour.serviceName(
            hostName: await RuntimeNetworkBonjour.resolvedHostName(),
            processName: RuntimeNetworkBonjour.localProcessName
        )
        let advertised = await RuntimeNetworkBonjour.resolvedServiceName()

        #expect(advertised == expected)
        #expect(!advertised.isEmpty)
        #expect(advertised.hasSuffix(" (\(RuntimeNetworkBonjour.localProcessName))"))
    }

    /// Uniqueness moved to the TXT record, so the name no longer has to carry
    /// it — but the shape that made the whole change necessary must still work:
    /// two payloads inside one simulator are told apart by device ID and pid.
    @Test("Two processes on one device stay distinct without the name")
    func twoProcessesStayDistinctWithoutNameUniqueness() {
        let first = Self.endpoint(name: "iPhone (gamecontrollerd)", deviceID: "DEVICE-A", processIdentifier: "58675")
        let second = Self.endpoint(name: "iPhone (gamecontrollerd)", deviceID: "DEVICE-A", processIdentifier: "3964")

        #expect(first.uniqueKey != second.uniqueKey)
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
