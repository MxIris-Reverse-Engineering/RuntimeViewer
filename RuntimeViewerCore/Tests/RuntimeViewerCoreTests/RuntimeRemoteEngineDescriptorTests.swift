import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

// MARK: - RuntimeRemoteEngineDescriptor Tests

@Suite("RuntimeRemoteEngineDescriptor")
struct RemoteEngineDescriptorTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "iPhone15,2", osVersion: "iOS 18.0.0")
        let source = RuntimeSource.remote(name: "TestDevice", identifier: "dev-123", role: .server)
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])

        let descriptor = RuntimeRemoteEngineDescriptor(
            engineID: "engine-1",
            source: source,
            hostName: "TestDevice",
            originChain: ["host-a", "host-b"],
            directTCPHost: "192.168.1.100",
            directTCPPort: 9090,
            metadata: metadata,
            iconData: iconData
        )
        #expect(descriptor.engineID == "engine-1")
        #expect(descriptor.source == source)
        #expect(descriptor.hostName == "TestDevice")
        #expect(descriptor.originChain == ["host-a", "host-b"])
        #expect(descriptor.directTCPHost == "192.168.1.100")
        #expect(descriptor.directTCPPort == 9090)
        #expect(descriptor.metadata == metadata)
        #expect(descriptor.iconData == iconData)
    }

    @Test("Default metadata and nil iconData")
    func defaultParameters() {
        let source = RuntimeSource.local
        let descriptor = RuntimeRemoteEngineDescriptor(
            engineID: "engine-1",
            source: source,
            hostName: "MyMac",
            originChain: [],
            directTCPHost: "127.0.0.1",
            directTCPPort: 8080
        )
        #expect(descriptor.metadata == RuntimeDeviceMetadata.current)
        #expect(descriptor.iconData == nil)
    }

    @Test("Empty origin chain")
    func emptyOriginChain() {
        let source = RuntimeSource.local
        let descriptor = RuntimeRemoteEngineDescriptor(
            engineID: "engine-1",
            source: source,
            hostName: "Host",
            originChain: [],
            directTCPHost: "localhost",
            directTCPPort: 8080
        )
        #expect(descriptor.originChain.isEmpty)
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "iPhone15,2", osVersion: "iOS 18.0.0")
        let source = RuntimeSource.bonjour(name: "MyPhone", identifier: "phone-1", role: .client)
        let original = RuntimeRemoteEngineDescriptor(
            engineID: "engine-42",
            source: source,
            hostName: "MyPhone",
            originChain: ["origin-1"],
            directTCPHost: "10.0.0.5",
            directTCPPort: 12345,
            metadata: metadata,
            iconData: Data([0x01, 0x02, 0x03])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeRemoteEngineDescriptor.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip with nil iconData")
    func codableNilIcon() throws {
        let source = RuntimeSource.local
        let original = RuntimeRemoteEngineDescriptor(
            engineID: "engine-1",
            source: source,
            hostName: "Host",
            originChain: [],
            directTCPHost: "localhost",
            directTCPPort: 8080,
            metadata: RuntimeDeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0"),
            iconData: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeRemoteEngineDescriptor.self, from: data)
        #expect(decoded.iconData == nil)
    }

    @Test("Decoding with missing optional fields")
    func codableWithMissingFields() throws {
        let json = """
        {
            "engineID": "engine-1",
            "source": {"local": {}},
            "hostName": "TestHost",
            "originChain": [],
            "directTCPHost": "localhost",
            "directTCPPort": 8080
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RuntimeRemoteEngineDescriptor.self, from: json)
        #expect(decoded.engineID == "engine-1")
        #expect(decoded.metadata == RuntimeDeviceMetadata.current)
        #expect(decoded.iconData == nil)
        // A peer predating `hostID` sends none; the receiver detects that by the
        // empty string and falls back to `originChain.first`.
        #expect(decoded.hostID == "")
    }

    /// `hostID` decides which section a mirrored engine joins. It has to survive
    /// the wire, or a mirror of a host lands in a section of its own instead of
    /// beside the direct route to that same host.
    @Test("Host ID survives a round-trip")
    func codableHostID() throws {
        let original = RuntimeRemoteEngineDescriptor(
            engineID: "engine-1",
            source: .bonjour(name: "SpringBoard", identifier: "DEVICE-A-42475", role: .client),
            hostID: "DEVICE-A",
            hostName: "iPhone 17 Pro",
            originChain: ["instance-1"],
            directTCPHost: "localhost",
            directTCPPort: 8080
        )
        let decoded = try JSONDecoder().decode(
            RuntimeRemoteEngineDescriptor.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded.hostID == "DEVICE-A")
        #expect(decoded.hostID != decoded.originChain.first)
        #expect(decoded == original)
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        let source = RuntimeSource.local
        let descriptorA = RuntimeRemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        let descriptorB = RuntimeRemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        let descriptorC = RuntimeRemoteEngineDescriptor(
            engineID: "e-2", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        #expect(descriptorA == descriptorB)
        #expect(descriptorA != descriptorC)
    }

    @Test("Hashable")
    func hashable() {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        let source = RuntimeSource.local
        let descriptorA = RuntimeRemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        let descriptorB = RuntimeRemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        var descriptorSet: Set<RuntimeRemoteEngineDescriptor> = []
        descriptorSet.insert(descriptorA)
        descriptorSet.insert(descriptorB)
        #expect(descriptorSet.count == 1)
    }
}
