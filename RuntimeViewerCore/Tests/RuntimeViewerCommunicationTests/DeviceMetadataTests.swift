import Testing
import Foundation
import RuntimeViewerCommunication

// MARK: - DeviceMetadata Tests

@Suite("DeviceMetadata")
struct DeviceMetadataTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let metadata = DeviceMetadata(
            modelIdentifier: "MacBookPro18,1",
            osVersion: "macOS 15.0.0",
            isSimulator: false,
            additionalInfo: ["key": "value"]
        )
        #expect(metadata.modelIdentifier == "MacBookPro18,1")
        #expect(metadata.osVersion == "macOS 15.0.0")
        #expect(metadata.isSimulator == false)
        #expect(metadata.additionalInfo == ["key": "value"])
    }

    @Test("Default parameter values")
    func defaultParameters() {
        let metadata = DeviceMetadata(
            modelIdentifier: "iPhone15,2",
            osVersion: "iOS 18.0.0"
        )
        #expect(metadata.isSimulator == false)
        #expect(metadata.additionalInfo.isEmpty)
    }

    @Test("Simulator device")
    func simulatorDevice() {
        let metadata = DeviceMetadata(
            modelIdentifier: "iPhone15,2",
            osVersion: "iOS 18.0.0",
            isSimulator: true
        )
        #expect(metadata.isSimulator == true)
    }

    // MARK: - Current

    @Test("Current metadata has non-empty values")
    func currentMetadata() {
        let current = DeviceMetadata.current
        #expect(!current.modelIdentifier.isEmpty)
        #expect(!current.osVersion.isEmpty)
        #expect(current.osVersion.contains("macOS"))
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let original = DeviceMetadata(
            modelIdentifier: "MacBookPro18,1",
            osVersion: "macOS 15.0.0",
            isSimulator: false,
            additionalInfo: ["buildNumber": "24A5289g"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding with missing optional fields uses defaults")
    func codableWithMissingFields() throws {
        let json = """
        {"modelIdentifier": "Test", "osVersion": "macOS 15.0.0"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DeviceMetadata.self, from: json)
        #expect(decoded.modelIdentifier == "Test")
        #expect(decoded.osVersion == "macOS 15.0.0")
        #expect(decoded.isSimulator == false)
        #expect(decoded.additionalInfo.isEmpty)
    }

    @Test("Decoding simulator flag from JSON")
    func codableSimulatorFlag() throws {
        let json = """
        {"modelIdentifier": "iPhone15,2", "osVersion": "iOS 18.0.0", "isSimulator": true, "additionalInfo": {}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DeviceMetadata.self, from: json)
        #expect(decoded.isSimulator == true)
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let metadataA = DeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        let metadataB = DeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        let metadataC = DeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 14.0.0")
        #expect(metadataA == metadataB)
        #expect(metadataA != metadataC)
    }

    @Test("Hashable")
    func hashable() {
        let metadataA = DeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        let metadataB = DeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        #expect(metadataA.hashValue == metadataB.hashValue)

        var metadataSet: Set<DeviceMetadata> = []
        metadataSet.insert(metadataA)
        metadataSet.insert(metadataB)
        #expect(metadataSet.count == 1)
    }

    @Test("AdditionalInfo mutability")
    func additionalInfoMutability() {
        var metadata = DeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        #expect(metadata.additionalInfo.isEmpty)
        metadata.additionalInfo["key"] = "value"
        #expect(metadata.additionalInfo["key"] == "value")
    }
}

// MARK: - HostInfo Tests

@Suite("HostInfo")
struct HostInfoTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let metadata = DeviceMetadata(modelIdentifier: "MacBookPro18,1", osVersion: "macOS 15.0.0")
        let hostInfo = HostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        #expect(hostInfo.hostID == "host-123")
        #expect(hostInfo.hostName == "MyMac")
        #expect(hostInfo.metadata == metadata)
    }

    @Test("Default metadata parameter")
    func defaultMetadata() {
        let hostInfo = HostInfo(hostID: "host-123", hostName: "MyMac")
        #expect(hostInfo.metadata == DeviceMetadata.current)
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let metadata = DeviceMetadata(modelIdentifier: "MacBookPro18,1", osVersion: "macOS 15.0.0")
        let original = HostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostInfo.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding with missing metadata uses current")
    func codableWithMissingMetadata() throws {
        let json = """
        {"hostID": "host-456", "hostName": "TestHost"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HostInfo.self, from: json)
        #expect(decoded.hostID == "host-456")
        #expect(decoded.hostName == "TestHost")
        #expect(decoded.metadata == DeviceMetadata.current)
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let metadata = DeviceMetadata(modelIdentifier: "MacBookPro18,1", osVersion: "macOS 15.0.0")
        let hostInfoA = HostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        let hostInfoB = HostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        let hostInfoC = HostInfo(hostID: "host-456", hostName: "OtherMac", metadata: metadata)
        #expect(hostInfoA == hostInfoB)
        #expect(hostInfoA != hostInfoC)
    }

    @Test("Hashable")
    func hashable() {
        let metadata = DeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        let hostInfoA = HostInfo(hostID: "id-1", hostName: "Host", metadata: metadata)
        let hostInfoB = HostInfo(hostID: "id-1", hostName: "Host", metadata: metadata)
        var hostInfoSet: Set<HostInfo> = []
        hostInfoSet.insert(hostInfoA)
        hostInfoSet.insert(hostInfoB)
        #expect(hostInfoSet.count == 1)
    }
}

// MARK: - RemoteEngineDescriptor Tests

@Suite("RemoteEngineDescriptor")
struct RemoteEngineDescriptorTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let metadata = DeviceMetadata(modelIdentifier: "iPhone15,2", osVersion: "iOS 18.0.0")
        let source = RuntimeSource.remote(name: "TestDevice", identifier: "dev-123", role: .server)
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])

        let descriptor = RemoteEngineDescriptor(
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
        let descriptor = RemoteEngineDescriptor(
            engineID: "engine-1",
            source: source,
            hostName: "MyMac",
            originChain: [],
            directTCPHost: "127.0.0.1",
            directTCPPort: 8080
        )
        #expect(descriptor.metadata == DeviceMetadata.current)
        #expect(descriptor.iconData == nil)
    }

    @Test("Empty origin chain")
    func emptyOriginChain() {
        let source = RuntimeSource.local
        let descriptor = RemoteEngineDescriptor(
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
        let metadata = DeviceMetadata(modelIdentifier: "iPhone15,2", osVersion: "iOS 18.0.0")
        let source = RuntimeSource.bonjour(name: "MyPhone", identifier: "phone-1", role: .client)
        let original = RemoteEngineDescriptor(
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
        let decoded = try JSONDecoder().decode(RemoteEngineDescriptor.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip with nil iconData")
    func codableNilIcon() throws {
        let source = RuntimeSource.local
        let original = RemoteEngineDescriptor(
            engineID: "engine-1",
            source: source,
            hostName: "Host",
            originChain: [],
            directTCPHost: "localhost",
            directTCPPort: 8080,
            metadata: DeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0"),
            iconData: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteEngineDescriptor.self, from: data)
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
        let decoded = try JSONDecoder().decode(RemoteEngineDescriptor.self, from: json)
        #expect(decoded.engineID == "engine-1")
        #expect(decoded.metadata == DeviceMetadata.current)
        #expect(decoded.iconData == nil)
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let metadata = DeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        let source = RuntimeSource.local
        let descriptorA = RemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        let descriptorB = RemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        let descriptorC = RemoteEngineDescriptor(
            engineID: "e-2", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        #expect(descriptorA == descriptorB)
        #expect(descriptorA != descriptorC)
    }

    @Test("Hashable")
    func hashable() {
        let metadata = DeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        let source = RuntimeSource.local
        let descriptorA = RemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        let descriptorB = RemoteEngineDescriptor(
            engineID: "e-1", source: source, hostName: "H", originChain: [],
            directTCPHost: "localhost", directTCPPort: 8080, metadata: metadata
        )
        var descriptorSet: Set<RemoteEngineDescriptor> = []
        descriptorSet.insert(descriptorA)
        descriptorSet.insert(descriptorB)
        #expect(descriptorSet.count == 1)
    }
}
