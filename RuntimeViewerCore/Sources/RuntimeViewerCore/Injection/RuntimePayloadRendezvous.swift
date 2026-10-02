// `public import` because `URL` crosses the public API below, and this module
// builds with `InternalImportsByDefault`.
public import Foundation
import RuntimeViewerCommunication

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
    ///
    /// **It disambiguates; it does not authenticate.** It is staged in a
    /// world-readable directory, because the payload binary beside it has to be
    /// world-readable for the target to map it. Treating the token as a secret
    /// would be a claim the layout cannot support — and would buy nothing, since
    /// anyone who could read it could equally load the payload sitting next to
    /// it.
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

// MARK: - Building one

extension RuntimePayloadRendezvous {
    /// Builds the rendezvous for an injection requested through `engine`.
    ///
    /// Everything comes from somewhere that knows rather than from a guess: the
    /// address off the live connection to the machine being injected, the port
    /// from the kernel, the token freshly minted.
    ///
    /// - Throws: ``Unavailable/peerCannotReachThisProcess`` when the engine's
    ///   transport cannot name an address. That is not a failure to work around
    ///   — it means nothing knows how the payload would get back here, and
    ///   injecting anyway would produce a target that silently never appears.
    public static func reachingThisProcess(
        from engine: RuntimeEngine
    ) async throws -> RuntimePayloadRendezvous {
        let reachability = await engine.localAddressSeenByPeer
        guard case .reachableAt(let hostAddress) = reachability else {
            guard case .unknown(let reason) = reachability else {
                // Unreachable: the enum has two cases and the first was ruled
                // out above. Stated rather than force-unwrapped away.
                throw Unavailable.peerCannotReachThisProcess(engineName: engine.source.description, reason: "no address was reported")
            }
            throw Unavailable.peerCannotReachThisProcess(engineName: engine.source.description, reason: reason)
        }
        return RuntimePayloadRendezvous(
            hostAddress: hostAddress,
            hostPort: try RuntimeUnusedPort.find(),
            claimToken: makeClaimToken(),
        )
    }

    public enum Unavailable: Error, LocalizedError, CustomStringConvertible {
        /// `reason` completes the sentence "the address could not be worked out
        /// because …", and comes from the connection itself rather than from
        /// this type — only the transport knows which of several things it was.
        case peerCannotReachThisProcess(engineName: String, reason: String)

        public var description: String {
            switch self {
            case .peerCannotReachThisProcess(let engineName, let reason):
                return """
                    Could not work out an address \(engineName) could reach this Mac on, because \(reason).

                    An injected payload on a device has to connect back here, because the \
                    process it is injected into is not allowed to listen, and the address it \
                    dials comes from the live connection to that device.
                    """
            }
        }

        public var errorDescription: String? { description }
    }
}

// MARK: - Finding it on disk

extension RuntimePayloadRendezvous {
    /// The name the injector writes it under, in the directory it stages the
    /// payload into.
    public static let fileName = "rendezvous.json"

    /// Reads the rendezvous staged beside a loaded image.
    ///
    /// `imageHandle` is how the payload says "beside *me*" — pass `#dsohandle`
    /// from inside the payload itself. The handle is a parameter rather than
    /// read here because `#dsohandle` expands at its use site: taken in this
    /// file it would name `RuntimeViewerCore`, which in the staged layout sits
    /// one directory further down, under `Frameworks/`.
    ///
    /// Deriving the location from the image rather than from a fixed path is
    /// what lets the injector choose the staging directory — it already can,
    /// and the payload has no other way to learn which one was used.
    public static func stagedBesideImage(_ imageHandle: UnsafeRawPointer) -> RuntimePayloadRendezvous? {
        guard let imagePath = pathOfImage(at: imageHandle) else { return nil }
        return stagedInDirectory(
            at: URL(fileURLWithPath: imagePath).deletingLastPathComponent()
        )
    }

    /// Reads the rendezvous out of a staging directory.
    ///
    /// Answers `nil` for every way this can come up empty — no file, unreadable,
    /// malformed, or describing nowhere to connect to — because the payload does
    /// the same thing in all of them: fall back to advertising itself. A thrown
    /// error would have to be turned back into that at the call site, inside a
    /// process where nothing can be reported to anyone.
    public static func stagedInDirectory(at directoryURL: URL) -> RuntimePayloadRendezvous? {
        let fileURL = directoryURL.appendingPathComponent(fileName)
        guard let contents = try? Data(contentsOf: fileURL),
              let rendezvous = try? JSONDecoder().decode(RuntimePayloadRendezvous.self, from: contents),
              rendezvous.isUsable
        else { return nil }
        return rendezvous
    }

    private static func pathOfImage(at imageHandle: UnsafeRawPointer) -> String? {
        var imageInformation = Dl_info()
        guard dladdr(imageHandle, &imageInformation) != 0,
              let fileName = imageInformation.dli_fname
        else { return nil }
        return String(cString: fileName)
    }
}
