#if os(macOS)

import Testing
import Foundation
import RuntimeViewerCommunication

// MARK: - PingRequest Tests

@Suite("PingRequest")
struct PingRequestTests {
    @Test("Identifier")
    func identifier() {
        #expect(PingRequest.identifier == "com.JH.RuntimeViewerService.Ping")
    }

    @Test("Initialization")
    func initialization() {
        let request = PingRequest()
        _ = request  // Ensure it can be constructed
    }

    @Test("Response type is VoidResponse")
    func responseType() {
        let _: PingRequest.Response = VoidResponse()
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = PingRequest()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PingRequest.self, from: data)
        _ = decoded
    }
}

// MARK: - FileOperation Tests

@Suite("FileOperation")
struct FileOperationTests {
    @Test("createDirectory case")
    func createDirectory() throws {
        let url = URL(fileURLWithPath: "/tmp/test")
        let operation = FileOperation.createDirectory(url: url, isIntermediateDirectories: true)
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(FileOperation.self, from: data)
        if case .createDirectory(let decodedURL, let isIntermediate) = decoded {
            #expect(decodedURL == url)
            #expect(isIntermediate == true)
        } else {
            Issue.record("Expected .createDirectory case")
        }
    }

    @Test("remove case")
    func remove() throws {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let operation = FileOperation.remove(url: url)
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(FileOperation.self, from: data)
        if case .remove(let decodedURL) = decoded {
            #expect(decodedURL == url)
        } else {
            Issue.record("Expected .remove case")
        }
    }

    @Test("move case")
    func move() throws {
        let fromURL = URL(fileURLWithPath: "/tmp/source.txt")
        let toURL = URL(fileURLWithPath: "/tmp/dest.txt")
        let operation = FileOperation.move(from: fromURL, to: toURL)
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(FileOperation.self, from: data)
        if case .move(let decodedFrom, let decodedTo) = decoded {
            #expect(decodedFrom == fromURL)
            #expect(decodedTo == toURL)
        } else {
            Issue.record("Expected .move case")
        }
    }

    @Test("copy case")
    func copy() throws {
        let fromURL = URL(fileURLWithPath: "/tmp/source.txt")
        let toURL = URL(fileURLWithPath: "/tmp/copy.txt")
        let operation = FileOperation.copy(from: fromURL, to: toURL)
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(FileOperation.self, from: data)
        if case .copy(let decodedFrom, let decodedTo) = decoded {
            #expect(decodedFrom == fromURL)
            #expect(decodedTo == toURL)
        } else {
            Issue.record("Expected .copy case")
        }
    }

    @Test("write case")
    func write() throws {
        let url = URL(fileURLWithPath: "/tmp/output.bin")
        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let operation = FileOperation.write(url: url, data: testData)
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(FileOperation.self, from: data)
        if case .write(let decodedURL, let decodedData) = decoded {
            #expect(decodedURL == url)
            #expect(decodedData == testData)
        } else {
            Issue.record("Expected .write case")
        }
    }
}

// MARK: - FileOperationRequest Tests

@Suite("FileOperationRequest")
struct FileOperationRequestTests {
    @Test("Identifier")
    func identifier() {
        #expect(FileOperationRequest.identifier == "com.JH.RuntimeViewerService.FileOperationRequest")
    }

    @Test("Initialization")
    func initialization() {
        let operation = FileOperation.remove(url: URL(fileURLWithPath: "/tmp/test"))
        let request = FileOperationRequest(operation: operation)
        if case .remove = request.operation {
            // success
        } else {
            Issue.record("Expected .remove operation")
        }
    }

    @Test("Response type is VoidResponse")
    func responseType() {
        let _: FileOperationRequest.Response = VoidResponse()
    }

    @Test("Codable round-trip")
    func codable() throws {
        let operation = FileOperation.createDirectory(url: URL(fileURLWithPath: "/tmp/dir"), isIntermediateDirectories: false)
        let original = FileOperationRequest(operation: operation)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileOperationRequest.self, from: data)
        if case .createDirectory(let url, let isIntermediate) = decoded.operation {
            #expect(url == URL(fileURLWithPath: "/tmp/dir"))
            #expect(isIntermediate == false)
        } else {
            Issue.record("Expected .createDirectory operation")
        }
    }
}

// MARK: - InjectApplicationRequest Tests

@Suite("InjectApplicationRequest")
struct InjectApplicationRequestTests {
    @Test("Identifier")
    func identifier() {
        #expect(InjectApplicationRequest.identifier == "com.JH.RuntimeViewerService.InjectApplication")
    }

    @Test("Initialization")
    func initialization() {
        let request = InjectApplicationRequest(
            pid: 12345,
            dylibURL: URL(fileURLWithPath: "/usr/lib/libinjector.dylib")
        )
        #expect(request.pid == 12345)
        #expect(request.dylibURL == URL(fileURLWithPath: "/usr/lib/libinjector.dylib"))
    }

    @Test("Response type is VoidResponse")
    func responseType() {
        let _: InjectApplicationRequest.Response = VoidResponse()
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = InjectApplicationRequest(
            pid: 42,
            dylibURL: URL(fileURLWithPath: "/tmp/inject.dylib")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InjectApplicationRequest.self, from: data)
        #expect(decoded.pid == original.pid)
        #expect(decoded.dylibURL == original.dylibURL)
    }
}

// MARK: - OpenApplicationRequest Tests

@Suite("OpenApplicationRequest")
struct OpenApplicationRequestTests {
    @Test("Identifier")
    func identifier() {
        #expect(OpenApplicationRequest.identifier == "com.JH.RuntimeViewerService.OpenApplicationRequest")
    }

    @Test("Initialization")
    func initialization() {
        let request = OpenApplicationRequest(
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            callerPID: 999
        )
        #expect(request.url == URL(fileURLWithPath: "/Applications/Safari.app"))
        #expect(request.callerPID == 999)
    }

    @Test("Response type is VoidResponse")
    func responseType() {
        let _: OpenApplicationRequest.Response = VoidResponse()
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = OpenApplicationRequest(
            url: URL(fileURLWithPath: "/Applications/Xcode.app"),
            callerPID: 1234
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenApplicationRequest.self, from: data)
        #expect(decoded.url == original.url)
        #expect(decoded.callerPID == original.callerPID)
    }
}

// MARK: - RemoveInjectedEndpointRequest Tests

@Suite("RemoveInjectedEndpointRequest")
struct RemoveInjectedEndpointRequestTests {
    @Test("Identifier")
    func identifier() {
        #expect(RemoveInjectedEndpointRequest.identifier == "com.JH.RuntimeViewerService.RemoveInjectedEndpoint")
    }

    @Test("Initialization")
    func initialization() {
        let request = RemoveInjectedEndpointRequest(pid: 5678)
        #expect(request.pid == 5678)
    }

    @Test("Response type is VoidResponse")
    func responseType() {
        let _: RemoveInjectedEndpointRequest.Response = VoidResponse()
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = RemoveInjectedEndpointRequest(pid: 42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoveInjectedEndpointRequest.self, from: data)
        #expect(decoded.pid == original.pid)
    }
}

// MARK: - FetchAllInjectedEndpointsRequest Tests

@Suite("FetchAllInjectedEndpointsRequest")
struct FetchAllInjectedEndpointsRequestTests {
    @Test("Identifier")
    func identifier() {
        #expect(FetchAllInjectedEndpointsRequest.identifier == "com.JH.RuntimeViewerService.FetchAllInjectedEndpoints")
    }

    @Test("Initialization")
    func initialization() {
        let request = FetchAllInjectedEndpointsRequest()
        _ = request
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = FetchAllInjectedEndpointsRequest()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FetchAllInjectedEndpointsRequest.self, from: data)
        _ = decoded
    }

    @Test("Response with empty endpoints")
    func emptyResponse() throws {
        let response = FetchAllInjectedEndpointsRequest.Response(endpoints: [])
        #expect(response.endpoints.isEmpty)

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(FetchAllInjectedEndpointsRequest.Response.self, from: data)
        #expect(decoded.endpoints.isEmpty)
    }
}

// MARK: - Request Identifier Uniqueness Tests

@Suite("Request identifiers")
struct RequestIdentifierTests {
    @Test("All request identifiers are unique")
    func uniqueIdentifiers() {
        let identifiers: [String] = [
            PingRequest.identifier,
            FileOperationRequest.identifier,
            InjectApplicationRequest.identifier,
            OpenApplicationRequest.identifier,
            RemoveInjectedEndpointRequest.identifier,
            FetchAllInjectedEndpointsRequest.identifier,
        ]
        let uniqueIdentifiers = Set(identifiers)
        #expect(uniqueIdentifiers.count == identifiers.count, "Request identifiers must be unique")
    }

    @Test("All request identifiers have correct prefix")
    func identifierPrefix() {
        let identifiers: [String] = [
            PingRequest.identifier,
            FileOperationRequest.identifier,
            InjectApplicationRequest.identifier,
            OpenApplicationRequest.identifier,
            RemoveInjectedEndpointRequest.identifier,
            FetchAllInjectedEndpointsRequest.identifier,
        ]
        for identifier in identifiers {
            #expect(identifier.hasPrefix("com.JH.RuntimeViewerService.") || identifier.hasPrefix("com.mxiris."))
        }
    }
}

#endif
