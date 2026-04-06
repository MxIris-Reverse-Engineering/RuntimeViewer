import Testing
import Foundation
import RuntimeViewerCommunication

// MARK: - RuntimeConnectionInfo Tests

@Suite("RuntimeConnectionInfo")
struct RuntimeConnectionInfoTests {
    @Test("Initialization")
    func initialization() {
        let connectionInfo = RuntimeConnectionInfo(host: "192.168.1.1", port: 8080)
        #expect(connectionInfo.host == "192.168.1.1")
        #expect(connectionInfo.port == 8080)
    }

    @Test("Localhost connection")
    func localhost() {
        let connectionInfo = RuntimeConnectionInfo(host: "127.0.0.1", port: 0)
        #expect(connectionInfo.host == "127.0.0.1")
        #expect(connectionInfo.port == 0)
    }

    @Test("Maximum port number")
    func maxPort() {
        let connectionInfo = RuntimeConnectionInfo(host: "localhost", port: 65535)
        #expect(connectionInfo.port == 65535)
    }
}

// MARK: - RuntimeNetworkError Tests

@Suite("RuntimeNetworkError")
struct RuntimeNetworkErrorTests {
    @Test("All error cases can be created")
    func allCases() {
        let errors: [RuntimeNetworkError] = [
            .notConnected,
            .invalidPort,
            .receiveFailed,
        ]
        #expect(errors.count == 3)
    }

    @Test("Errors conform to Error protocol")
    func conformsToError() {
        let error: Error = RuntimeNetworkError.notConnected
        #expect(error is RuntimeNetworkError)
    }
}

// MARK: - RuntimeNetworkRequestError Tests

@Suite("RuntimeNetworkRequestError")
struct RuntimeNetworkRequestErrorTests {
    @Test("Decode from JSON and access message")
    func decodeFromJSON() throws {
        let json = """
        {"message": "Something went wrong"}
        """.data(using: .utf8)!
        let error = try JSONDecoder().decode(RuntimeNetworkRequestError.self, from: json)
        #expect(error.message == "Something went wrong")
    }

    @Test("Conforms to Error protocol")
    func conformsToError() throws {
        let json = """
        {"message": "test"}
        """.data(using: .utf8)!
        let error: Error = try JSONDecoder().decode(RuntimeNetworkRequestError.self, from: json)
        #expect(error is RuntimeNetworkRequestError)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let json = """
        {"message": "Network timeout"}
        """.data(using: .utf8)!
        let original = try JSONDecoder().decode(RuntimeNetworkRequestError.self, from: json)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data)
        #expect(decoded.message == original.message)
    }
}

// MARK: - RuntimeNetworkBonjour Tests

@Suite("RuntimeNetworkBonjour")
struct RuntimeNetworkBonjourTests {
    @Test("Service type constant")
    func serviceType() {
        #expect(RuntimeNetworkBonjour.type == "_runtimeviewer._tcp")
    }

    @Test("TXT record key constants")
    func txtRecordKeys() {
        #expect(RuntimeNetworkBonjour.instanceIDKey == "rv-instance-id")
        #expect(RuntimeNetworkBonjour.hostNameKey == "rv-host-name")
        #expect(RuntimeNetworkBonjour.modelIDKey == "rv-model-id")
        #expect(RuntimeNetworkBonjour.osVersionKey == "rv-os-ver")
        #expect(RuntimeNetworkBonjour.isSimulatorKey == "rv-sim")
    }

    @Test("Local instance ID is non-empty and stable")
    func localInstanceID() {
        let instanceID = RuntimeNetworkBonjour.localInstanceID
        #expect(!instanceID.isEmpty)
        // Should return the same value on repeated access
        #expect(RuntimeNetworkBonjour.localInstanceID == instanceID)
    }

    @Test("Local host name is non-empty")
    func localHostName() {
        let hostName = RuntimeNetworkBonjour.localHostName
        #expect(!hostName.isEmpty)
    }
}
