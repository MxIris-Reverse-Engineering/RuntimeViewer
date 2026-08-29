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
}
