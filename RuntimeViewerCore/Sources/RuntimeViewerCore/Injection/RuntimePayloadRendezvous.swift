import Foundation

/// Everything the injector hands the payload: where to report in, and what to
/// report as.
///
/// It exists because the payload cannot work either one out for itself. It runs
/// inside a process it does not own, under that process's sandbox and with that
/// process's entitlements, and both of the things it used to derive locally turn
/// out to depend on the host process:
///
/// - **Where.** The payload used to listen and advertise itself over Bonjour, so
///   the address was "wherever I am". But the kernel denies `network-bind` to
///   most iOS daemons, and the payload inherits that denial — measured, four of
///   seven targets on one device could not open a listener at all. Connecting
///   outward is permitted where binding is not, so the direction is reversed and
///   the destination has to come from outside.
/// - **What.** The payload used to derive the device identity itself, and
///   `MobileGestalt` answers according to the *target's* entitlements: measured,
///   `sharingd` could answer and `chronod` could not, so the same device
///   reported two different identities and the host's claim never matched. A
///   token minted by the host removes the derivation entirely — the host only
///   ever has to recognize a value it issued.
///
/// Written beside the staged payload as JSON and read back by the payload at
/// startup. Absent means the injector predates this and the payload falls back
/// to advertising itself, which is still what the simulator does.
///
/// Background: `Documentations/Evolutions/draft-device-payload-reverse-connection.md`.
public struct RuntimePayloadRendezvous: Codable, Sendable, Hashable {
    /// The host's address as reached *from the device*.
    ///
    /// Filled in by the host, which is the only party that can: the payload sees
    /// the device's own interfaces, not the route back.
    public let hostAddress: String

    /// The port the host is listening on for this injection.
    public let hostPort: UInt16

    /// What the payload presents on connecting, and the only thing the host
    /// matches on.
    ///
    /// The host issues it, so recognizing it needs no knowledge of the device,
    /// the target process or anything else the payload would have had to derive.
    public let claimToken: String

    public init(hostAddress: String, hostPort: UInt16, claimToken: String) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.claimToken = claimToken
    }

    /// A fresh token for one injection.
    ///
    /// One per injection rather than one per device or per session: two
    /// injections can be in flight at once — the picker allows it, and a user
    /// retrying a target that timed out produces it — and a token shared between
    /// them would let the host hand the first arrival to the wrong request.
    public static func makeClaimToken() -> String {
        UUID().uuidString
    }

    /// Whether this rendezvous names somewhere to connect to.
    ///
    /// Checked by the payload before it acts on one, because the alternative is
    /// worse than a missing file: a rendezvous with an empty address makes the
    /// payload abandon the advertising path *and* fail to connect, so it would
    /// go silent where it used to at least work on the targets that can bind.
    public var isUsable: Bool {
        !hostAddress.isEmpty && hostPort != 0 && !claimToken.isEmpty
    }
}
