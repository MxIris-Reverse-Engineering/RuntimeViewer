import Testing
import Foundation
import RuntimeViewerCommunication

// MARK: - RuntimeDeviceMetadata Tests

@Suite("RuntimeDeviceMetadata")
struct DeviceMetadataTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let metadata = RuntimeDeviceMetadata(
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
        let metadata = RuntimeDeviceMetadata(
            modelIdentifier: "iPhone15,2",
            osVersion: "iOS 18.0.0"
        )
        #expect(metadata.isSimulator == false)
        #expect(metadata.additionalInfo.isEmpty)
    }

    @Test("Simulator device")
    func simulatorDevice() {
        let metadata = RuntimeDeviceMetadata(
            modelIdentifier: "iPhone15,2",
            osVersion: "iOS 18.0.0",
            isSimulator: true
        )
        #expect(metadata.isSimulator == true)
    }

    // MARK: - Current

    @Test("Current metadata has non-empty values")
    func currentMetadata() {
        let current = RuntimeDeviceMetadata.current
        #expect(!current.modelIdentifier.isEmpty)
        #expect(!current.osVersion.isEmpty)
        #expect(current.osVersion.contains("macOS"))
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let original = RuntimeDeviceMetadata(
            modelIdentifier: "MacBookPro18,1",
            osVersion: "macOS 15.0.0",
            isSimulator: false,
            additionalInfo: ["buildNumber": "24A5289g"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeDeviceMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding with missing optional fields uses defaults")
    func codableWithMissingFields() throws {
        let json = """
        {"modelIdentifier": "Test", "osVersion": "macOS 15.0.0"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RuntimeDeviceMetadata.self, from: json)
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
        let decoded = try JSONDecoder().decode(RuntimeDeviceMetadata.self, from: json)
        #expect(decoded.isSimulator == true)
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let metadataA = RuntimeDeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        let metadataB = RuntimeDeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        let metadataC = RuntimeDeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 14.0.0")
        #expect(metadataA == metadataB)
        #expect(metadataA != metadataC)
    }

    @Test("Hashable")
    func hashable() {
        let metadataA = RuntimeDeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        let metadataB = RuntimeDeviceMetadata(modelIdentifier: "MacPro1,1", osVersion: "macOS 15.0.0")
        #expect(metadataA.hashValue == metadataB.hashValue)

        var metadataSet: Set<RuntimeDeviceMetadata> = []
        metadataSet.insert(metadataA)
        metadataSet.insert(metadataB)
        #expect(metadataSet.count == 1)
    }

    @Test("AdditionalInfo mutability")
    func additionalInfoMutability() {
        var metadata = RuntimeDeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        #expect(metadata.additionalInfo.isEmpty)
        metadata.additionalInfo["key"] = "value"
        #expect(metadata.additionalInfo["key"] == "value")
    }
}

// MARK: - RuntimeHostInfo Tests

@Suite("RuntimeHostInfo")
struct HostInfoTests {
    // MARK: - Initialization

    @Test("Initialization with all properties")
    func initialization() {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "MacBookPro18,1", osVersion: "macOS 15.0.0")
        let hostInfo = RuntimeHostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        #expect(hostInfo.hostID == "host-123")
        #expect(hostInfo.hostName == "MyMac")
        #expect(hostInfo.metadata == metadata)
    }

    @Test("Default metadata parameter")
    func defaultMetadata() {
        let hostInfo = RuntimeHostInfo(hostID: "host-123", hostName: "MyMac")
        #expect(hostInfo.metadata == RuntimeDeviceMetadata.current)
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "MacBookPro18,1", osVersion: "macOS 15.0.0")
        let original = RuntimeHostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeHostInfo.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding with missing metadata uses current")
    func codableWithMissingMetadata() throws {
        let json = """
        {"hostID": "host-456", "hostName": "TestHost"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RuntimeHostInfo.self, from: json)
        #expect(decoded.hostID == "host-456")
        #expect(decoded.hostName == "TestHost")
        #expect(decoded.metadata == RuntimeDeviceMetadata.current)
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "MacBookPro18,1", osVersion: "macOS 15.0.0")
        let hostInfoA = RuntimeHostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        let hostInfoB = RuntimeHostInfo(hostID: "host-123", hostName: "MyMac", metadata: metadata)
        let hostInfoC = RuntimeHostInfo(hostID: "host-456", hostName: "OtherMac", metadata: metadata)
        #expect(hostInfoA == hostInfoB)
        #expect(hostInfoA != hostInfoC)
    }

    @Test("Hashable")
    func hashable() {
        let metadata = RuntimeDeviceMetadata(modelIdentifier: "Test", osVersion: "macOS 15.0.0")
        let hostInfoA = RuntimeHostInfo(hostID: "id-1", hostName: "Host", metadata: metadata)
        let hostInfoB = RuntimeHostInfo(hostID: "id-1", hostName: "Host", metadata: metadata)
        var hostInfoSet: Set<RuntimeHostInfo> = []
        hostInfoSet.insert(hostInfoA)
        hostInfoSet.insert(hostInfoB)
        #expect(hostInfoSet.count == 1)
    }
}
