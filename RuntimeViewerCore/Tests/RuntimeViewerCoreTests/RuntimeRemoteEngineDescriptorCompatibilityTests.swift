import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

/// Mixed-version wire compatibility for the bookmark scope identity that
/// `RuntimeRemoteEngineDescriptor` now carries.
///
/// Descriptors travel between peers that need not run the same build, so both
/// directions have to be proven, and neither direction may be proven by letting
/// the current type encode and decode its own output — that only ever restates
/// that a type agrees with itself. So the old shape is a hand-written JSON
/// fixture, and the old *reader* is a frozen copy of the struct as it stood
/// before the field existed.
@Suite("RuntimeRemoteEngineDescriptor mixed-version compatibility")
struct RuntimeRemoteEngineDescriptorCompatibilityTests {
    /// A descriptor exactly as a peer predating the identity field emits it.
    /// Frozen by hand from that version's encoder output; do not regenerate it
    /// from the current type.
    private static let descriptorFromPeerWithoutIdentityField = """
    {
      "directTCPHost" : "192.168.1.10",
      "directTCPPort" : 9000,
      "engineID" : "DEVICE/bonjour.11111111-2222-3333-4444-555555555555-4242",
      "hostID" : "11111111-2222-3333-4444-555555555555",
      "hostName" : "JHs-iPhone",
      "metadata" : {
        "additionalInfo" : {},
        "isSimulator" : true,
        "modelIdentifier" : "iPhone17,1",
        "osVersion" : "26.0"
      },
      "originChain" : [
        "instance-a"
      ],
      "source" : {
        "bonjour" : {
          "identifier" : "11111111-2222-3333-4444-555555555555-4242",
          "name" : "SpringBoard",
          "role" : {
            "client" : {}
          }
        }
      }
    }
    """

    /// A descriptor from a peer old enough that its Bonjour identifier is still
    /// a service name, so nothing can be recovered from it.
    private static let descriptorFromPeerWithServiceNameIdentifier = """
    {
      "directTCPHost" : "192.168.1.10",
      "directTCPPort" : 9000,
      "engineID" : "instance-a/bonjour.JHs-iPhone (RuntimeViewer)",
      "hostName" : "JHs-iPhone",
      "originChain" : [
        "instance-a"
      ],
      "source" : {
        "bonjour" : {
          "identifier" : "JHs-iPhone (RuntimeViewer)",
          "name" : "JHs-iPhone (RuntimeViewer)",
          "role" : {
            "client" : {}
          }
        }
      }
    }
    """

    /// The struct as it stood before the identity field, used to read what the
    /// current version writes.
    private struct FrozenPreIdentityDescriptor: Decodable {
        let engineID: String
        let source: RuntimeSource
        let hostID: String
        let hostName: String
        let originChain: [String]
        let directTCPHost: String
        let directTCPPort: UInt16
        let metadata: RuntimeDeviceMetadata
        let iconData: Data?
    }

    private func makeDescriptor(stableIdentity: String) -> RuntimeRemoteEngineDescriptor {
        RuntimeRemoteEngineDescriptor(
            engineID: "DEVICE/bonjour.11111111-2222-3333-4444-555555555555-4242",
            source: .bonjour(
                name: "SpringBoard",
                identifier: "11111111-2222-3333-4444-555555555555-4242",
                role: .client
            ),
            hostID: "11111111-2222-3333-4444-555555555555",
            stableIdentity: stableIdentity,
            hostName: "JHs-iPhone",
            originChain: ["instance-a"],
            directTCPHost: "192.168.1.10",
            directTCPPort: 9000,
            metadata: .init(modelIdentifier: "iPhone17,1", osVersion: "26.0", isSimulator: true),
            iconData: nil
        )
    }

    // MARK: New reads old

    @Test("A descriptor from a peer without the field decodes, with the field empty")
    func newReadsOld() throws {
        let data = Data(Self.descriptorFromPeerWithoutIdentityField.utf8)
        let descriptor = try JSONDecoder().decode(RuntimeRemoteEngineDescriptor.self, from: data)

        #expect(descriptor.stableIdentity.isEmpty)
        #expect(descriptor.hostID == "11111111-2222-3333-4444-555555555555")
        #expect(descriptor.source.description == "SpringBoard")
    }

    @Test("An absent field falls back to what the source can still prove")
    func absentFieldRecoversFromSource() throws {
        let data = Data(Self.descriptorFromPeerWithoutIdentityField.utf8)
        let descriptor = try JSONDecoder().decode(RuntimeRemoteEngineDescriptor.self, from: data)

        #expect(
            descriptor.bookmarkScope == .identified(.bonjour(
                deviceID: "11111111-2222-3333-4444-555555555555",
                processName: "SpringBoard",
                role: .client
            ))
        )
    }

    @Test("A source that proves nothing falls back to the per-consumer legacy keys")
    func unrecoverableSourceFallsBackToLegacy() throws {
        let data = Data(Self.descriptorFromPeerWithServiceNameIdentifier.utf8)
        let descriptor = try JSONDecoder().decode(RuntimeRemoteEngineDescriptor.self, from: data)

        #expect(descriptor.bookmarkScope == .legacy(for: descriptor.source))
        #expect(descriptor.bookmarkScope.bookmarkKey == descriptor.source.identifier)
        #expect(descriptor.bookmarkScope.sidebarAutosaveKey == descriptor.source.description)
    }

    @Test("A field the current version cannot parse is treated as absent, not trusted")
    func unparsableIdentityIsTreatedAsAbsent() {
        let descriptor = makeDescriptor(stableIdentity: "v9:something:from:the:future")
        #expect(
            descriptor.bookmarkScope == .identified(.bonjour(
                deviceID: "11111111-2222-3333-4444-555555555555",
                processName: "SpringBoard",
                role: .client
            ))
        )
    }

    @Test("A present field is used verbatim, without re-deriving it")
    func presentIdentityIsUsedVerbatim() {
        // Deliberately unlike anything recovery would produce, so the test can
        // tell "used the wire value" from "recomputed and happened to match".
        let descriptor = makeDescriptor(stableIdentity: "v1:bonjour:client:OTHER-DEVICE:OtherProcess")
        #expect(
            descriptor.bookmarkScope == .identified(.bonjour(
                deviceID: "OTHER-DEVICE",
                processName: "OtherProcess",
                role: .client
            ))
        )
    }

    // MARK: Old reads new

    @Test("A peer predating the field reads a current descriptor unharmed")
    func oldReadsNew() throws {
        let descriptor = makeDescriptor(stableIdentity: "v1:bonjour:client:11111111-2222-3333-4444-555555555555:SpringBoard")
        let data = try JSONEncoder().encode(descriptor)

        let asSeenByOldPeer = try JSONDecoder().decode(FrozenPreIdentityDescriptor.self, from: data)

        #expect(asSeenByOldPeer.engineID == descriptor.engineID)
        #expect(asSeenByOldPeer.hostID == descriptor.hostID)
        #expect(asSeenByOldPeer.hostName == descriptor.hostName)
        #expect(asSeenByOldPeer.originChain == descriptor.originChain)
        #expect(asSeenByOldPeer.directTCPHost == descriptor.directTCPHost)
        #expect(asSeenByOldPeer.directTCPPort == descriptor.directTCPPort)
        #expect(asSeenByOldPeer.source == descriptor.source)
    }

    @Test("The source's own encoded shape is unchanged by any of this")
    func sourceEncodingIsUntouched() throws {
        let source = RuntimeSource.bonjour(name: "SpringBoard", identifier: "DEVICE-4242", role: .client)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(source), as: UTF8.self)

        #expect(json == #"{"bonjour":{"identifier":"DEVICE-4242","name":"SpringBoard","role":{"client":{}}}}"#)
    }

    // MARK: Adding a source case

    /// `RuntimeSource` as it stood when engine mirroring shipped.
    ///
    /// **Five cases, and deliberately not the current type.** The frozen
    /// descriptor above reuses `RuntimeSource` itself, so it proves nothing
    /// about a case being *added* — the very change this guards. `Codable` here
    /// is synthesized, exactly as it is on the real type, so a new case encodes
    /// as a key this reader has no match for.
    private enum FrozenFiveCaseSource: Codable, Equatable {
        case local
        case remote(name: String, identifier: String, role: RuntimeSource.Role)
        case bonjour(name: String, identifier: String, role: RuntimeSource.Role)
        case localSocket(name: String, identifier: String, role: RuntimeSource.Role)
        case directTCP(name: String, host: String?, port: UInt16, role: RuntimeSource.Role)
    }

    /// **One undecodable element fails the whole array, not just that element.**
    ///
    /// This is what makes a new case a mixed-version break rather than a
    /// cosmetic gap: `engineList` is one `JSONDecoder` call over
    /// `[RuntimeRemoteEngineDescriptor]`, so a peer that cannot read one
    /// descriptor reads none of them — and the heartbeat counts that as a dead
    /// link, so after two consecutive failures it stops the engine and takes
    /// every mirrored engine from that peer with it.
    ///
    /// Characterization, not a regression test: this is the receiver that is
    /// already shipped and cannot be changed. It is here to say why the sending
    /// side has to be the one that holds the line.
    @Test("A source case the old reader lacks fails the entire descriptor array")
    func oneUnknownCaseFailsTheWholeArray() throws {
        let readable = RuntimeSource.bonjour(name: "SpringBoard", identifier: "DEVICE-4242", role: .client)
        let unreadable = RuntimeSource.injectedTCP(
            name: "sharingd",
            host: "192.168.64.1",
            port: 51234,
            identifier: "A-CLAIM-TOKEN",
            role: .client,
        )
        let data = try JSONEncoder().encode([readable, unreadable])

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([FrozenFiveCaseSource].self, from: data)
        }
        // The readable one on its own is fine, so it really is the new case.
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode([FrozenFiveCaseSource].self, from: try JSONEncoder().encode([readable]))
        }
    }

    /// The rule the sending side holds: **nothing that an already-shipped peer
    /// cannot decode may be put in front of one.**
    ///
    /// Stated over the source kinds rather than over one case, so that adding a
    /// case fails here unless its author has decided which side of the line it
    /// falls on. A case that is mirrorable must survive the frozen reader; a
    /// case that is not is simply never advertised.
    @Test(
        "Every mirrorable source kind decodes in a peer that predates this build",
        arguments: [
            RuntimeSource.local,
            .remote(name: "Catalyst", identifier: "catalyst", role: .client),
            .bonjour(name: "SpringBoard", identifier: "DEVICE-4242", role: .client),
            .localSocket(name: "Finder", identifier: "4242", role: .client),
            .directTCP(name: "Mirrored", host: "10.0.0.2", port: 50000, role: .client),
            .injectedTCP(name: "sharingd", host: "192.168.64.1", port: 51234, identifier: "TOKEN", role: .client),
        ],
    )
    func mirrorableSourcesStayReadableByOlderPeers(source: RuntimeSource) throws {
        guard source.isMirrorableToPeers else { return }
        let data = try JSONEncoder().encode(source)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(FrozenFiveCaseSource.self, from: data)
        }
    }
}
