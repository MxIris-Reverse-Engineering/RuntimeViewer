#if canImport(Network)

import Testing
import Foundation
import Semantic
#if canImport(SwiftyXPC)
import SwiftyXPC
#endif
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// Mixed-version wire compatibility for the interface request, whose reply
/// carries `RuntimeObjectInterface.interfaceString`.
///
/// Builds up to 3.0.0-beta.6 write `interfaceString` as `SemanticString`'s
/// array of components and cannot read `FrozenSemanticString`'s columnar
/// encoding, and engine connections exchange no protocol version: a Mac of
/// this build meets 3.0.0-beta.6 iPhones, Macs and injected payloads as a
/// matter of course. Every combination below therefore runs over a real
/// connection, through the command table `RuntimeEngineProxyServer` serves,
/// against a peer frozen as it shipped. The shipped reply is a hand-written
/// JSON fixture; the shipped request and the shipped reader are copies of the
/// types as 3.0.0-beta.6 declares them. None of it is produced by the current
/// types — a type encoding and decoding its own output only proves that it
/// agrees with itself.
@Suite("Interface request mixed-version compatibility", .serialized)
struct RuntimeObjectInterfaceWireCompatibilityTests {
    // MARK: - The shipped peer

    /// `InterfaceCommand` as 3.0.0-beta.6 declares it, under the name it had
    /// then, `InterfaceRequest`.
    private struct ShippedInterfaceRequest: Codable {
        let object: RuntimeObject
        let options: RuntimeObjectInterface.GenerationOptions
    }

    /// `RuntimeObjectInterface` as 3.0.0-beta.6 declares it: how a shipped
    /// client reads the reply.
    private struct ShippedRuntimeObjectInterface: Codable {
        let object: RuntimeObject
        let interfaceString: SemanticString
    }

    /// The reply of a 3.0.0-beta.6 server. Written by hand from that
    /// version's types — `SemanticString` encodes as an array of
    /// `{string, type, identifier?}`, `SemanticType` with the synthesized enum
    /// encoding — so never regenerate it from current code.
    private static let replyFromShippedServer = #"""
    {
      "object" : {
        "children" : [],
        "displayName" : "NSObject",
        "imagePath" : "/usr/lib/libobjc.A.dylib",
        "kind" : { "objc" : { "_0" : { "type" : { "_0" : { "class" : {} } } } } },
        "name" : "NSObject",
        "properties" : 0
      },
      "interfaceString" : [
        { "string" : "@interface", "type" : { "keyword" : {} } },
        { "string" : " ", "type" : { "standard" : {} } },
        { "string" : "NSObject", "type" : { "type" : { "_0" : { "class" : {} }, "_1" : { "declaration" : {} } } } },
        { "string" : " <", "type" : { "standard" : {} } },
        { "identifier" : "NSObjectProtocolIdentity", "string" : "NSObject", "type" : { "type" : { "_0" : { "protocol" : {} }, "_1" : { "name" : {} } } } },
        { "string" : ">\n@end", "type" : { "standard" : {} } }
      ]
    }
    """#

    /// What `replyFromShippedServer` says, component by component.
    private static let shippedInterfaceComponents: [AtomicComponent] = [
        AtomicComponent(string: "@interface", type: .keyword),
        AtomicComponent(string: " ", type: .standard),
        AtomicComponent(string: "NSObject", type: .type(.class, .declaration)),
        AtomicComponent(string: " <", type: .standard),
        AtomicComponent(string: "NSObject", type: .type(.protocol, .name), identifier: "NSObjectProtocolIdentity"),
        AtomicComponent(string: ">\n@end", type: .standard),
    ]

    private static let object = RuntimeObject(
        name: "NSObject",
        displayName: "NSObject",
        kind: .objc(.type(.class)),
        imagePath: "/usr/lib/libobjc.A.dylib",
        children: []
    )

    /// A 3.0.0-beta.6 server: it reads the interface request as that version
    /// declares it, failing the request the way it would if it could not, and
    /// answers with `replyFromShippedServer`.
    private struct ShippedServer: Sendable {
        let connection: RuntimeDirectTCPServerConnection
        let receivedRequests = ReceivedValues<JSONValue>()

        var port: UInt16 { connection.port }

        static func listen() async throws -> ShippedServer {
            try await ShippedServer(connection: RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false))
        }

        /// The TCP server has no connection to mount a handler on before a
        /// peer connects.
        func serveConnectedPeer() async throws {
            try await waitUntilConnected(connection)
            let reply = try JSONDecoder().decode(JSONValue.self, from: Data(RuntimeObjectInterfaceWireCompatibilityTests.replyFromShippedServer.utf8))
            let receivedRequests = receivedRequests
            connection.setMessageHandler(name: RuntimeEngine.InterfaceCommand.commandName) { (request: JSONValue) -> JSONValue in
                await receivedRequests.record(request)
                _ = try JSONDecoder().decode(ShippedInterfaceRequest.self, from: JSONEncoder().encode(request))
                return reply
            }
        }

        func stop() {
            connection.stop()
        }
    }

    // MARK: - Peers of this build

    /// An engine of this build shared over a TCP listener with the command
    /// table `RuntimeEngineProxyServer` installs. With a client engine behind
    /// it, it is a relay: what a Mac does when it shares on an engine it
    /// mirrors from elsewhere.
    private struct ServingPeer: Sendable {
        let engine: RuntimeEngine
        let connection: RuntimeDirectTCPServerConnection

        var port: UInt16 { connection.port }

        static func listen(serving engine: RuntimeEngine) async throws -> ServingPeer {
            try await ServingPeer(engine: engine, connection: RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false))
        }

        func serveConnectedPeer() async throws {
            try await waitUntilConnected(connection)
            RuntimeEngine.registerSharedHandlers(on: connection, engine: engine)
        }

        func stop() async {
            connection.stop()
            await engine.stop()
        }
    }

    private static func makeLocalEngine(_ engineID: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        try await engine.connect()
        return engine
    }

    private static func makeClientEngine(_ engineID: String, connectingTo port: UInt16) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .directTCP(name: engineID, host: "127.0.0.1", port: port, role: .client), engineID: engineID)
        try await engine.connect()
        return engine
    }

    private static func requestAsShippedClient(over connection: RuntimeDirectTCPClientConnection) async throws -> ShippedRuntimeObjectInterface? {
        try await connection.sendMessage(
            name: RuntimeEngine.InterfaceCommand.commandName,
            request: ShippedInterfaceRequest(object: object, options: RuntimeObjectInterface.GenerationOptions()),
            timeout: 10
        )
    }

    // MARK: - The fixture

    @Test("the fixture is what a 3.0.0-beta.6 reader reads")
    func fixtureIsAShippedReply() throws {
        let reply = try JSONDecoder().decode(ShippedRuntimeObjectInterface.self, from: Data(Self.replyFromShippedServer.utf8))

        #expect(reply.object.hasSameContent(as: Self.object))
        #expect(reply.interfaceString.components == Self.shippedInterfaceComponents)
    }

    // MARK: - New client, shipped server

    @Test("a client of this build reads the reply of a server that predates the columnar encoding")
    func clientReadsReplyOfShippedServer() async throws {
        let shippedServer = try await ShippedServer.listen()
        let client = try await Self.makeClientEngine("interface-wire-compatibility.client", connectingTo: shippedServer.port)
        defer { Task { await client.stop(); shippedServer.stop() } }
        try await shippedServer.serveConnectedPeer()

        let interface = try #require(try await withDeadline(seconds: 10) {
            try await client.interface(for: Self.object, options: RuntimeObjectInterface.GenerationOptions())
        })

        #expect(interface.object.hasSameContent(as: Self.object))
        #expect(interface.interfaceString.string == "@interface NSObject <NSObject>\n@end")
        #expect(interface.interfaceString.components == Self.shippedInterfaceComponents)
        // The shipped server read this build's request, including the key it
        // does not know — which says that this build reads the columnar form.
        let requests = await shippedServer.receivedRequests.values
        #expect(requests.count == 1)
        #expect(requests.first?["acceptsColumnarInterfaceString"] == .boolean(true), "the request does not declare the columnar encoding: \(String(describing: requests.first))")
    }

    // MARK: - Shipped client, new server

    @Test("a client that predates the columnar encoding reads the reply of a server of this build")
    func shippedClientReadsReplyOfServer() async throws {
        let server = try await ServingPeer.listen(serving: Self.makeLocalEngine("interface-wire-compatibility.server"))
        let shippedClient = try await RuntimeDirectTCPClientConnection(host: "127.0.0.1", port: server.port)
        defer { Task { shippedClient.stop(); await server.stop() } }
        try await server.serveConnectedPeer()

        let reply = try #require(try await Self.requestAsShippedClient(over: shippedClient))

        let expected = try #require(try await server.engine.interface(for: Self.object, options: RuntimeObjectInterface.GenerationOptions()))
        #expect(reply.object.hasSameContent(as: Self.object))
        #expect(reply.interfaceString.string == expected.interfaceString.string)
        #expect(reply.interfaceString.components == expected.interfaceString.components)
    }

    // MARK: - New client, new server

    @Test("a request that declares the columnar encoding is answered in it")
    func columnarRequestIsAnsweredInColumnarEncoding() async throws {
        /// `InterfaceCommand` as this build sends it, written out by hand.
        struct DeclaringInterfaceRequest: Codable {
            let object: RuntimeObject
            let options: RuntimeObjectInterface.GenerationOptions
            let acceptsColumnarInterfaceString: Bool
        }

        let server = try await ServingPeer.listen(serving: Self.makeLocalEngine("interface-wire-compatibility.columnar-server"))
        let client = try await RuntimeDirectTCPClientConnection(host: "127.0.0.1", port: server.port)
        defer { Task { client.stop(); await server.stop() } }
        try await server.serveConnectedPeer()

        let reply: JSONValue = try await client.sendMessage(
            name: RuntimeEngine.InterfaceCommand.commandName,
            request: DeclaringInterfaceRequest(object: Self.object, options: RuntimeObjectInterface.GenerationOptions(), acceptsColumnarInterfaceString: true),
            timeout: 10
        )

        guard case .object(let interfaceStringFields)? = reply["interfaceString"] else {
            Issue.record("interfaceString is not the columnar object: \(String(describing: reply["interfaceString"]))")
            return
        }
        #expect(Set(interfaceStringFields.keys) == ["text", "spanLengths", "spanTypeCodes", "spanIdentifierIndices", "identifierTable"])
    }

    @Test("a client of this build reads the reply of a server of this build")
    func clientReadsReplyOfServer() async throws {
        let server = try await ServingPeer.listen(serving: Self.makeLocalEngine("interface-wire-compatibility.current-server"))
        let client = try await Self.makeClientEngine("interface-wire-compatibility.current-client", connectingTo: server.port)
        defer { Task { await client.stop(); await server.stop() } }
        try await server.serveConnectedPeer()

        let interface = try #require(try await withDeadline(seconds: 10) {
            try await client.interface(for: Self.object, options: RuntimeObjectInterface.GenerationOptions())
        })

        let expected = try #require(try await server.engine.interface(for: Self.object, options: RuntimeObjectInterface.GenerationOptions()))
        #expect(interface.object.hasSameContent(as: Self.object))
        #expect(interface.interfaceString == expected.interfaceString)
    }

    // MARK: - Through a relay of this build

    @Test("a client that predates the columnar encoding reads a server that predates it through a relay of this build")
    func shippedClientReadsShippedServerThroughRelay() async throws {
        let shippedServer = try await ShippedServer.listen()
        let relayEngine = try await Self.makeClientEngine("interface-wire-compatibility.relay-to-shipped", connectingTo: shippedServer.port)
        try await shippedServer.serveConnectedPeer()
        let relay = try await ServingPeer.listen(serving: relayEngine)
        let shippedClient = try await RuntimeDirectTCPClientConnection(host: "127.0.0.1", port: relay.port)
        defer { Task { shippedClient.stop(); await relay.stop(); shippedServer.stop() } }
        try await relay.serveConnectedPeer()

        let reply = try #require(try await Self.requestAsShippedClient(over: shippedClient))

        #expect(reply.interfaceString.components == Self.shippedInterfaceComponents)
    }

    @Test("a client of this build reads a server that predates the columnar encoding through a relay of this build")
    func clientReadsShippedServerThroughRelay() async throws {
        let shippedServer = try await ShippedServer.listen()
        let relayEngine = try await Self.makeClientEngine("interface-wire-compatibility.relay-for-current", connectingTo: shippedServer.port)
        try await shippedServer.serveConnectedPeer()
        let relay = try await ServingPeer.listen(serving: relayEngine)
        let client = try await Self.makeClientEngine("interface-wire-compatibility.client-behind-relay", connectingTo: relay.port)
        defer { Task { await client.stop(); await relay.stop(); shippedServer.stop() } }
        try await relay.serveConnectedPeer()

        let interface = try #require(try await withDeadline(seconds: 10) {
            try await client.interface(for: Self.object, options: RuntimeObjectInterface.GenerationOptions())
        })

        #expect(interface.interfaceString.components == Self.shippedInterfaceComponents)
    }

    @Test("a client that predates the columnar encoding reads a server of this build through a relay of this build")
    func shippedClientReadsServerThroughRelay() async throws {
        let server = try await ServingPeer.listen(serving: Self.makeLocalEngine("interface-wire-compatibility.server-behind-relay"))
        let relayEngine = try await Self.makeClientEngine("interface-wire-compatibility.relay-to-current", connectingTo: server.port)
        try await server.serveConnectedPeer()
        let relay = try await ServingPeer.listen(serving: relayEngine)
        let shippedClient = try await RuntimeDirectTCPClientConnection(host: "127.0.0.1", port: relay.port)
        defer { Task { shippedClient.stop(); await relay.stop(); await server.stop() } }
        try await relay.serveConnectedPeer()

        let reply = try #require(try await Self.requestAsShippedClient(over: shippedClient))

        let expected = try #require(try await server.engine.interface(for: Self.object, options: RuntimeObjectInterface.GenerationOptions()))
        #expect(reply.interfaceString.components == expected.interfaceString.components)
    }

    // MARK: - The encodings themselves

    @Test("no interface travels as null, whatever the request declares", arguments: [nil, false, true] as [Bool?])
    func missingInterfaceIsNull(acceptsColumnarInterfaceString: Bool?) throws {
        let request = RuntimeEngine.InterfaceCommand(
            object: Self.object,
            options: RuntimeObjectInterface.GenerationOptions(),
            acceptsColumnarInterfaceString: acceptsColumnarInterfaceString
        )

        let data = try JSONEncoder().encode(request.response(for: nil))

        #expect(String(decoding: data, as: UTF8.self) == "null")
        #expect(try JSONDecoder().decode(ShippedRuntimeObjectInterface?.self, from: data) == nil)
        #expect(try JSONDecoder().decode(RuntimeObjectInterfaceResponse.self, from: data).interface == nil)
    }

    @Test("a reply in neither encoding fails with the error of the columnar one")
    func replyInNeitherEncodingFailsWithColumnarError() throws {
        let shippedReply = try JSONDecoder().decode(JSONValue.self, from: Data(Self.replyFromShippedServer.utf8))
        guard case .object(var fields) = shippedReply else {
            Issue.record("the fixture is not an object")
            return
        }
        fields["interfaceString"] = .integer(42)
        let data = try JSONEncoder().encode(JSONValue.object(fields))

        let columnarError = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeObjectInterface.self, from: data)
        }
        let responseError = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeObjectInterfaceResponse.self, from: data)
        }
        #expect(String(describing: responseError) == String(describing: columnarError))
    }

    #if canImport(SwiftyXPC)
    // A Mach service connection encodes with SwiftyXPC rather than JSON, and
    // an injected 3.0.0-beta.6 payload answers through one.

    @Test("over a Mach service, a client of this build reads the reply of a server that predates the columnar encoding")
    func clientReadsMachServiceReplyOfShippedServer() throws {
        let shippedReply = try JSONDecoder().decode(JSONValue.self, from: Data(Self.replyFromShippedServer.utf8))
        let encodedReply = try XPCEncoder().encode(Optional(shippedReply))

        let response = try XPCDecoder().decode(type: RuntimeObjectInterfaceResponse.self, from: encodedReply)

        let interface = try #require(response.interface)
        #expect(interface.object.hasSameContent(as: Self.object))
        #expect(interface.interfaceString.components == Self.shippedInterfaceComponents)
        #expect(response.interfaceStringEncoding == .components)
    }

    @Test("over a Mach service, a client that predates the columnar encoding reads the reply to its request")
    func shippedClientReadsMachServiceReply() throws {
        let shippedRequest = ShippedInterfaceRequest(object: Self.object, options: RuntimeObjectInterface.GenerationOptions())
        let request = try XPCDecoder().decode(type: RuntimeEngine.InterfaceCommand.self, from: XPCEncoder().encode(shippedRequest))
        let interface = RuntimeObjectInterface(object: Self.object, interfaceString: SemanticString(components: Self.shippedInterfaceComponents))

        let encodedReply = try XPCEncoder().encode(request.response(for: interface))

        let shippedReply = try #require(try XPCDecoder().decode(type: ShippedRuntimeObjectInterface?.self, from: encodedReply))
        #expect(request.acceptsColumnarInterfaceString == nil)
        #expect(shippedReply.interfaceString.components == Self.shippedInterfaceComponents)
    }

    @Test("over a Mach service, two peers of this build exchange the columnar encoding")
    func currentPeersExchangeColumnarEncodingOverMachService() throws {
        let request = RuntimeEngine.InterfaceCommand(object: Self.object, options: RuntimeObjectInterface.GenerationOptions(), acceptsColumnarInterfaceString: true)
        let interface = RuntimeObjectInterface(object: Self.object, interfaceString: SemanticString(components: Self.shippedInterfaceComponents))

        let encodedReply = try XPCEncoder().encode(request.response(for: interface))

        let response = try XPCDecoder().decode(type: RuntimeObjectInterfaceResponse.self, from: encodedReply)
        #expect(response.interfaceStringEncoding == .columnar)
        #expect(response.interface?.interfaceString == interface.interfaceString)
    }
    #endif
}

// MARK: - Support

/// A JSON document held as a tree, so that a fixture crosses a connection
/// exactly as it is written, with no current type producing it.
private enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: Key.self) {
            var fields: [String: JSONValue] = [:]
            for key in container.allKeys {
                fields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(fields)
        } else if var container = try? decoder.unkeyedContainer() {
            var elements: [JSONValue] = []
            while !container.isAtEnd {
                elements.append(try container.decode(JSONValue.self))
            }
            self = .array(elements)
        } else {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let boolean = try? container.decode(Bool.self) {
                self = .boolean(boolean)
            } else if let integer = try? container.decode(Int.self) {
                self = .integer(integer)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .object(let fields):
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in fields {
                try container.encode(value, forKey: Key(stringValue: key))
            }
        case .array(let elements):
            var container = encoder.unkeyedContainer()
            for element in elements {
                try container.encode(element)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .integer(let integer):
            var container = encoder.singleValueContainer()
            try container.encode(integer)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .boolean(let boolean):
            var container = encoder.singleValueContainer()
            try container.encode(boolean)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private actor ReceivedValues<Value: Sendable> {
    private(set) var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }
}

private struct ConnectionDeadlineError: Swift.Error {}

/// Spins until `connection` reports `.connected`, failing past the deadline.
private func waitUntilConnected(_ connection: some RuntimeConnection, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while connection.state != .connected {
        guard Date() < deadline else { throw ConnectionDeadlineError() }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

private struct OperationDeadlineError: Swift.Error {}

private final class ResumeOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return false }
        isResumed = true
        return true
    }
}

/// Races `operation` against a deadline without waiting for the loser, so a
/// peer that never answers fails the test instead of hanging the run. A task
/// group would not do: leaving its scope waits for every child.
private func withDeadline<Value: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let flag = ResumeOnceFlag()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Swift.Error>) in
        Task {
            do {
                let value = try await operation()
                if flag.tryResume() { continuation.resume(returning: value) }
            } catch {
                if flag.tryResume() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if flag.tryResume() { continuation.resume(throwing: OperationDeadlineError()) }
        }
    }
}

#endif
