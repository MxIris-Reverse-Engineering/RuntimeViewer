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
///
/// Class template nodes (proposal `cplusplus-class-template-groups`) follow the
/// same way: a requester says it knows them with a second optional field, and
/// one of a build before them — which asks for C++ objects and could not
/// decode the node's kind — gets each template's specializations where the
/// node would be.
@Suite("C++ objects over the wire", .serialized)
struct ObjectsInImageCPlusPlusWireTests {
    /// `ObjectsInImageCommand`'s request as releases before C++ objects wrote
    /// and read it. Frozen: never replace it with the current type.
    private struct ShippedObjectsInImageRequest: Codable, Equatable, Sendable {
        let image: String
    }

    /// `ObjectsInImageCommand`'s request as releases from C++ objects until
    /// class template nodes wrote and read it. Frozen: never replace it with
    /// the current type.
    private struct ShippedCPlusPlusObjectsInImageRequest: Codable, Equatable, Sendable {
        let image: String
        let includesCPlusPlusObjects: Bool?
    }

    private static let imagePath = CPlusPlusSectionTests.libcxxabiPath

    /// An image with class templates: libc++ instantiates `basic_string`.
    private static let classTemplateImagePath = CPlusPlusSectionTests.libcxxPath

    private static func containsClassTemplateNode(_ objects: [RuntimeObject]) -> Bool {
        CPlusPlusSectionTests.flattened(objects).values.contains { $0.kind == .cPlusPlus(.classTemplate) }
    }

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

    @Test("a request for C++ objects says it knows class template nodes")
    func requestWithCPlusPlusObjectsCarriesTheClassTemplateFlag() throws {
        let flagged = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath, includesCPlusPlusObjects: true)
        #expect(flagged.includesCPlusPlusClassTemplates == true)
        #expect(try Self.json(flagged).contains(#""includesCPlusPlusClassTemplates":true"#))
        let unflagged = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath)
        #expect(unflagged.includesCPlusPlusClassTemplates == nil)
        #expect(!(try Self.json(unflagged)).contains("includesCPlusPlusClassTemplates"))
    }

    @Test("a server of a build before class template nodes reads the request without that flag")
    func serverOfAnEarlierBuildReadsTheFlaggedRequestWithout() throws {
        let request = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath, includesCPlusPlusObjects: true)
        let shippedRequest = try JSONDecoder().decode(ShippedCPlusPlusObjectsInImageRequest.self, from: JSONEncoder().encode(request))
        #expect(shippedRequest == ShippedCPlusPlusObjectsInImageRequest(image: Self.imagePath, includesCPlusPlusObjects: true))
        // A request of that build, read by this one: C++ objects without class template nodes.
        let decodedByThisBuild = try JSONDecoder().decode(RuntimeEngine.ObjectsInImageCommand.self, from: JSONEncoder().encode(shippedRequest))
        #expect(decodedByThisBuild.includesCPlusPlusObjects == true)
        #expect(decodedByThisBuild.includesCPlusPlusClassTemplates == nil)
    }

    @Test("a requester that does not know class template nodes gets the specializations where they were")
    func requesterWithoutTheClassTemplateFlagGetsSpecializationsWhereTheyWere() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "ObjectsInImageCPlusPlusWireTests.class-templates")
        try await engine.connect()
        defer { Task { await engine.stop() } }
        let earlierRequest = try JSONDecoder().decode(
            RuntimeEngine.ObjectsInImageCommand.self,
            from: JSONEncoder().encode(ShippedCPlusPlusObjectsInImageRequest(image: Self.classTemplateImagePath, includesCPlusPlusObjects: true))
        )
        let flat = CPlusPlusSectionTests.flattened(try await earlierRequest.perform(on: engine).filter(\.kind.isCPlusPlus))
        let grouped = CPlusPlusSectionTests.flattened(try await engine.objects(in: Self.classTemplateImagePath, includesCPlusPlusObjects: true).filter(\.kind.isCPlusPlus))
        let templateNames = Set(grouped.values.filter { $0.kind == .cPlusPlus(.classTemplate) }.map(\.name))
        #expect(!templateNames.isEmpty)
        #expect(!flat.values.contains { $0.kind == .cPlusPlus(.classTemplate) })
        #expect(Set(flat.keys) == Set(grouped.keys).subtracting(templateNames))
        // Each specialization sits directly in the scope it sits in through its template node.
        for (name, object) in flat {
            let groupedObject = try #require(grouped[name])
            let expectedChildren = groupedObject.children.flatMap { $0.kind == .cPlusPlus(.classTemplate) ? $0.children : [$0] }
            #expect(object.children.map(\.name) == expectedChildren.sorted().map(\.name), "\(name)")
        }
    }

    #if canImport(SwiftyXPC)
    @Test("over a Mach service, the flag crosses, and a server of an earlier build reads the request without it")
    func flagCrossesMachServiceEncoding() throws {
        let request = RuntimeEngine.ObjectsInImageCommand(image: Self.imagePath, includesCPlusPlusObjects: true)
        let decoded = try XPCDecoder().decode(type: RuntimeEngine.ObjectsInImageCommand.self, from: XPCEncoder().encode(request))
        #expect(decoded.includesCPlusPlusObjects == true)
        #expect(decoded.includesCPlusPlusClassTemplates == true)
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
        // A client of this build says it knows class template nodes, and gets them.
        #expect(Self.containsClassTemplateNode(try await pair.client.objects(in: Self.classTemplateImagePath, includesCPlusPlusObjects: true)))
    }

    @Test("a relay of this build forwards the flag, and the class template flag with it")
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
        #expect(Self.containsClassTemplateNode(try await client.objects(in: Self.classTemplateImagePath, includesCPlusPlusObjects: true)))
    }
}
#endif
