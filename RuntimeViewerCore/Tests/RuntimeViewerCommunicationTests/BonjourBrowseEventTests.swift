import Testing
import Foundation
import Network
@testable import RuntimeViewerCommunication

/// Covers which browse changes the browser reports to the host at all.
///
/// The gate under test exists because mDNS answers a service's TXT record
/// separately from the service record itself: a browse result can surface with
/// every identity field empty, and every downstream check then degrades to the
/// service name. The shipped failure this reproduces is the "ghost device" —
/// a host discovering *its own advertisement* without the TXT record, passing
/// its own self-filter (`nil` instance ID matches nothing), and connecting to
/// itself under a section named after the local machine; a peer that caught
/// the same window recorded the service name as the engine's origin, which no
/// cycle detection recognized, so the ghost also survived being mirrored back
/// across hosts.
@Suite("Bonjour browse events")
struct BonjourBrowseEventTests {
    private static func endpoint(
        name: String,
        instanceID: String? = nil,
        deviceID: String? = nil,
        processIdentifier: String? = nil
    ) -> RuntimeNetworkEndpoint {
        RuntimeNetworkEndpoint(
            name: name,
            instanceID: instanceID,
            hostName: nil,
            deviceMetadata: nil,
            deviceID: deviceID,
            processName: nil,
            processIdentifier: processIdentifier,
            endpoint: .service(name: name, type: RuntimeNetworkBonjour.type, domain: "local.", interface: nil)
        )
    }

    /// The ghost-device reproduction: a result whose TXT record has not
    /// arrived carries no instance identity, and reporting it is what let a
    /// host connect to its own advertisement. It must be held instead.
    @Test("An endpoint without an instance identity is not reported")
    func identitylessEndpointIsHeld() {
        let ghost = Self.endpoint(name: "JH's Mac Studio Ultra (RuntimeViewer)")

        #expect(RuntimeNetworkBrowser.events(forAdded: ghost).isEmpty)
    }

    @Test("An endpoint carrying its instance identity is reported")
    func identifiedEndpointIsReported() {
        let discovered = Self.endpoint(
            name: "JHs-iPhone (RuntimeViewer)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )

        #expect(RuntimeNetworkBrowser.events(forAdded: discovered) == [.added(discovered)])
    }

    /// The release valve for the hold above: when the TXT record arrives,
    /// `uniqueKey` moves from the service name to `{deviceID}-{pid}`, the
    /// change classifies as a replacement, and the identified endpoint must
    /// come out as an addition.
    @Test("A TXT record arriving upgrades a held endpoint into an addition")
    func txtRecordArrivalReportsHeldEndpoint() {
        let held = Self.endpoint(name: "JHs-iPhone (RuntimeViewer)")
        let identified = Self.endpoint(
            name: "JHs-iPhone (RuntimeViewer)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )

        #expect(
            RuntimeNetworkBrowser.events(forChangeFrom: held, to: identified)
                == [.removed(held), .added(identified)]
        )
    }

    /// The mid-flap shape: a listener re-registering can strip the TXT record
    /// off an already-known result. The stale side is reported as removed —
    /// which the manager deliberately ignores — but the identity-less
    /// successor must not be reported as an arrival, or the ghost connection
    /// happens right here.
    @Test("A TXT record vanishing mid-flap removes without re-adding")
    func txtRecordFlapSuppressesGhostAddition() {
        let identified = Self.endpoint(
            name: "JHs-iPhone (RuntimeViewer)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )
        let stripped = Self.endpoint(name: "JHs-iPhone (RuntimeViewer)")

        #expect(
            RuntimeNetworkBrowser.events(forChangeFrom: identified, to: stripped)
                == [.removed(identified)]
        )
    }

    @Test("A metadata-only change reports nothing")
    func metadataOnlyChangeIsSilent() {
        let before = Self.endpoint(
            name: "JHs-iPhone (RuntimeViewer)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )
        let after = Self.endpoint(
            name: "JHs-iPhone (RuntimeViewer)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )

        #expect(RuntimeNetworkBrowser.events(forChangeFrom: before, to: after).isEmpty)
    }

    /// A relaunched peer keeps its launch-stable name and moves only its pid;
    /// the host must hear about both halves of the replacement.
    @Test("A relaunched peer is reported as removal then arrival")
    func relaunchedPeerReportsBothHalves() {
        let before = Self.endpoint(
            name: "JHs-iPhone (SpringBoard)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )
        let after = Self.endpoint(
            name: "JHs-iPhone (SpringBoard)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "58675"
        )

        #expect(
            RuntimeNetworkBrowser.events(forChangeFrom: before, to: after)
                == [.removed(before), .added(after)]
        )
    }

    /// Removals stay unconditional: the manager's removal handling is
    /// deliberately inert, and a held endpoint that disappears before its TXT
    /// record ever arrived produces a removal nobody acted on — harmless.
    @Test("Removals pass through with or without an identity")
    func removalsAlwaysPassThrough() {
        let identified = Self.endpoint(
            name: "JHs-iPhone (RuntimeViewer)",
            instanceID: "INSTANCE-A",
            deviceID: "DEVICE-A",
            processIdentifier: "42475"
        )
        let identityless = Self.endpoint(name: "JHs-iPhone (RuntimeViewer)")

        #expect(RuntimeNetworkBrowser.events(forRemoved: identified) == [.removed(identified)])
        #expect(RuntimeNetworkBrowser.events(forRemoved: identityless) == [.removed(identityless)])
    }
}
