import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

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
