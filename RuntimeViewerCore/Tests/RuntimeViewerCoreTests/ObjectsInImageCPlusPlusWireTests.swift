#if canImport(Network) && os(macOS)
import Foundation
import Testing
#if canImport(SwiftyXPC)
import SwiftyXPC
#endif
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// C++ objects ride in `objectsInImage`'s reply, asked for by an optional
/// field of the request (`CommunicationAndEngineArchitecture.md` §4.4,
/// proposal `cplusplus-objects`): a requester of an earlier build never sets
/// it and reads the reply it always read, with no kind it cannot decode; a
/// peer of an earlier build skips it and answers with Objective-C and Swift
/// objects. No new command reaches a peer that may be old — an injected
/// payload of an earlier release drops its connection on one it does not
/// know (PR121.73).
@Suite("C++ objects over the wire", .serialized)
struct ObjectsInImageCPlusPlusWireTests {
    /// `ObjectsInImageCommand`'s request as releases before C++ objects wrote
    /// and read it. Frozen: never replace it with the current type.
    private struct ShippedObjectsInImageRequest: Codable, Equatable, Sendable {
        let image: String
    }

    private static let imagePath = CPlusPlusSectionTests.libcxxabiPath

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - The request

    @Test("a request without the flag encodes as a request of an earlier build")
    func requestWithoutFlagEncodesAsBefore() throws {
        let request = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath)
        #expect(request.includesCPlusPlusObjects == nil)
        #expect(try Self.json(request) == Self.json(ShippedObjectsInImageRequest(image: Self.imagePath)))
    }

    @Test("a flagged request carries the flag, and a server of an earlier build reads it without")
    func frozenOldServerReadsFlaggedRequestWithoutTheFlag() throws {
        let request = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath, includesCPlusPlusObjects: true)
        #expect(try Self.json(request).contains(#""includesCPlusPlusObjects":true"#))
        let shippedRequest = try JSONDecoder().decode(ShippedObjectsInImageRequest.self, from: JSONEncoder().encode(request))
        #expect(shippedRequest == ShippedObjectsInImageRequest(image: Self.imagePath))
        // What that server then runs: the objects without C++ ones.
        let decodedByThisBuild = try JSONDecoder().decode(RuntimeEngine.ObjectsInImageCommand.self, from: JSONEncoder().encode(shippedRequest))
        #expect(decodedByThisBuild.includesCPlusPlusObjects == nil)
    }

    #if canImport(SwiftyXPC)
    @Test("over a Mach service, the flag crosses, and a server of an earlier build reads the request without it")
    func flagCrossesMachServiceEncoding() throws {
        let request = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath, includesCPlusPlusObjects: true)
        let decoded = try XPCDecoder().decode(type: RuntimeEngine.ObjectsInImageCommand.self, from: XPCEncoder().encode(request))
        #expect(decoded.includesCPlusPlusObjects == true)
        let shippedRequest = try XPCDecoder().decode(type: ShippedObjectsInImageRequest.self, from: XPCEncoder().encode(request))
        #expect(shippedRequest.image == Self.imagePath)
        let unflagged = try XPCDecoder().decode(type: RuntimeEngine.ObjectsInImageCommand.self, from: XPCEncoder().encode(ShippedObjectsInImageRequest(image: Self.imagePath)))
        #expect(unflagged.includesCPlusPlusObjects == nil)
    }
    #endif

    // MARK: - Real connections

    @Test("a client gets C++ objects only when it asks for them", arguments: RemoteEnginePair.Transport.allCases)
    func flagCrossesBothTransports(transport: RemoteEnginePair.Transport) async throws {
        let label = "cplusplus-objects.\(transport)"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let pair = try await RemoteEnginePair.make(transport, label: label, serving: serving)
        defer {
            Task {
                await pair.stop()
                await serving.stop()
            }
        }
        let withoutFlag = try await pair.client.objects(in: Self.imagePath)
        #expect(!withoutFlag.contains { $0.kind.isCPlusPlus })
        let flagged = try await pair.client.objects(in: Self.imagePath, includesCPlusPlusObjects: true)
        #expect(CPlusPlusSectionTests.flattened(flagged)["std::bad_alloc"]?.kind == .cPlusPlus(.class))
    }

    @Test("a relay of this build forwards the flag")
    func relayForwardsTheFlag() async throws {
        let label = "cplusplus-objects.relay"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let upstream = try await RemoteEnginePair.make(.socket, label: label, serving: serving)
        let relayConnection = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let client = RuntimeEngine(
            source: .directTCP(name: "\(label).client", host: "127.0.0.1", port: relayConnection.port, role: .client),
            engineID: "\(label).client"
        )
        defer {
            Task {
                await client.stop()
                relayConnection.stop()
                await upstream.stop()
                await serving.stop()
            }
        }
        try await client.connect()
        let deadline = ContinuousClock.now + .seconds(5)
        while relayConnection.state != .connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        RuntimeEngine.registerSharedHandlers(on: relayConnection, engine: upstream.client)
        let flagged = try await client.objects(in: Self.imagePath, includesCPlusPlusObjects: true)
        #expect(CPlusPlusSectionTests.flattened(flagged)["std::bad_alloc"]?.kind == .cPlusPlus(.class))
        let withoutFlag = try await client.objects(in: Self.imagePath)
        #expect(!withoutFlag.contains { $0.kind.isCPlusPlus })
    }
}
#endif
