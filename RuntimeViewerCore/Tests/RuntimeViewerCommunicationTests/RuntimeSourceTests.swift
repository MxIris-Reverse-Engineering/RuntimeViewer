import Testing
import Foundation
import RuntimeViewerCommunication

@Suite("RuntimeSource")
struct RuntimeSourceTests {
    // MARK: - description

    @Test("local description is My Mac")
    func localDescription() {
        let source = RuntimeSource.local
        #expect(source.description == "My Mac")
    }

    @Test("remote description is the name")
    func remoteDescription() {
        let source = RuntimeSource.remote(name: "iPhone", identifier: "id1", role: .client)
        #expect(source.description == "iPhone")
    }

    @Test("bonjour description is the name")
    func bonjourDescription() {
        let source = RuntimeSource.bonjour(name: "iPad", identifier: "id2", role: .server)
        #expect(source.description == "iPad")
    }

    @Test("localSocket description is the name")
    func localSocketDescription() {
        let source = RuntimeSource.localSocket(name: "Injected App", identifier: "id3", role: .client)
        #expect(source.description == "Injected App")
    }

    @Test("directTCP description is the name")
    func directTCPDescription() {
        let source = RuntimeSource.directTCP(name: "TCP Host", host: "192.168.1.1", port: 8080, role: .server)
        #expect(source.description == "TCP Host")
    }

    // MARK: - isRemote

    @Test("local is not remote")
    func localNotRemote() {
        #expect(RuntimeSource.local.isRemote == false)
    }

    @Test("all non-local sources are remote")
    func nonLocalAreRemote() {
        #expect(RuntimeSource.remote(name: "A", identifier: "id", role: .client).isRemote == true)
        #expect(RuntimeSource.bonjour(name: "B", identifier: "id", role: .server).isRemote == true)
        #expect(RuntimeSource.localSocket(name: "C", identifier: "id", role: .client).isRemote == true)
        #expect(RuntimeSource.directTCP(name: "D", host: nil, port: 0, role: .server).isRemote == true)
    }

    // MARK: - remoteRole

    @Test("local has no remote role")
    func localNoRole() {
        #expect(RuntimeSource.local.remoteRole == nil)
    }

    @Test("non-local sources return their role")
    func nonLocalRoles() {
        #expect(RuntimeSource.remote(name: "A", identifier: "id", role: .client).remoteRole == .client)
        #expect(RuntimeSource.bonjour(name: "B", identifier: "id", role: .server).remoteRole == .server)
        #expect(RuntimeSource.localSocket(name: "C", identifier: "id", role: .client).remoteRole == .client)
        #expect(RuntimeSource.directTCP(name: "D", host: nil, port: 0, role: .server).remoteRole == .server)
    }

    // MARK: - isXPC

    @Test("only remote is XPC")
    func onlyRemoteIsXPC() {
        #expect(RuntimeSource.remote(name: "A", identifier: "id", role: .client).isXPC == true)
        #expect(RuntimeSource.local.isXPC == false)
        #expect(RuntimeSource.bonjour(name: "B", identifier: "id", role: .server).isXPC == false)
        #expect(RuntimeSource.localSocket(name: "C", identifier: "id", role: .client).isXPC == false)
        #expect(RuntimeSource.directTCP(name: "D", host: nil, port: 0, role: .server).isXPC == false)
    }

    // MARK: - Equatable

    @Test("local equals local")
    func localEquality() {
        #expect(RuntimeSource.local == RuntimeSource.local)
    }

    @Test("remote equality uses identifier and role, ignores name")
    func remoteEquality() {
        let a = RuntimeSource.remote(name: "A", identifier: "id1", role: .client)
        let b = RuntimeSource.remote(name: "B", identifier: "id1", role: .client)
        let c = RuntimeSource.remote(name: "A", identifier: "id2", role: .client)
        let d = RuntimeSource.remote(name: "A", identifier: "id1", role: .server)
        #expect(a == b) // Same id and role, different name
        #expect(a != c) // Different id
        #expect(a != d) // Different role
    }

    @Test("bonjour equality uses identifier and role")
    func bonjourEquality() {
        let a = RuntimeSource.bonjour(name: "A", identifier: "id1", role: .client)
        let b = RuntimeSource.bonjour(name: "B", identifier: "id1", role: .client)
        #expect(a == b)
    }

    @Test("localSocket equality uses identifier and role")
    func localSocketEquality() {
        let a = RuntimeSource.localSocket(name: "A", identifier: "id1", role: .client)
        let b = RuntimeSource.localSocket(name: "B", identifier: "id1", role: .client)
        #expect(a == b)
    }

    @Test("directTCP equality uses host, port, and role")
    func directTCPEquality() {
        let a = RuntimeSource.directTCP(name: "A", host: "127.0.0.1", port: 8080, role: .client)
        let b = RuntimeSource.directTCP(name: "B", host: "127.0.0.1", port: 8080, role: .client)
        let c = RuntimeSource.directTCP(name: "A", host: "127.0.0.1", port: 9090, role: .client)
        let d = RuntimeSource.directTCP(name: "A", host: "192.168.1.1", port: 8080, role: .client)
        #expect(a == b) // Same host/port/role, different name
        #expect(a != c) // Different port
        #expect(a != d) // Different host
    }

    @Test("different source types are never equal")
    func crossTypeInequality() {
        #expect(RuntimeSource.local != RuntimeSource.remote(name: "A", identifier: "id", role: .client))
        #expect(RuntimeSource.remote(name: "A", identifier: "id", role: .client) != RuntimeSource.bonjour(name: "A", identifier: "id", role: .client))
    }

    // MARK: - Hashable

    @Test("equal sources have same hash")
    func hashConsistency() {
        let a = RuntimeSource.remote(name: "A", identifier: "id1", role: .client)
        let b = RuntimeSource.remote(name: "B", identifier: "id1", role: .client)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("sources can be stored in Set")
    func setStorage() {
        let set: Set<RuntimeSource> = [
            .local,
            .remote(name: "A", identifier: "id1", role: .client),
            .remote(name: "B", identifier: "id1", role: .client), // Duplicate of above
            .bonjour(name: "C", identifier: "id2", role: .server),
        ]
        #expect(set.count == 3)
    }

    // MARK: - Codable

    @Test("local Codable round-trip")
    func localCodable() throws {
        let original = RuntimeSource.local
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.self, from: data)
        #expect(decoded == original)
    }

    @Test("remote Codable round-trip")
    func remoteCodable() throws {
        let original = RuntimeSource.remote(name: "MyDevice", identifier: "dev.id.123", role: .server)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.self, from: data)
        #expect(decoded == original)
    }

    @Test("bonjour Codable round-trip")
    func bonjourCodable() throws {
        let original = RuntimeSource.bonjour(name: "iPad", identifier: "bonjour.id", role: .client)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.self, from: data)
        #expect(decoded == original)
    }

    @Test("localSocket Codable round-trip")
    func localSocketCodable() throws {
        let original = RuntimeSource.localSocket(name: "Injected", identifier: "sock.id", role: .server)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.self, from: data)
        #expect(decoded == original)
    }

    @Test("directTCP Codable round-trip")
    func directTCPCodable() throws {
        let original = RuntimeSource.directTCP(name: "Server", host: "10.0.0.1", port: 9876, role: .client)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.self, from: data)
        #expect(decoded == original)
    }

    @Test("directTCP with nil host Codable round-trip")
    func directTCPNilHostCodable() throws {
        let original = RuntimeSource.directTCP(name: "Server", host: nil, port: 0, role: .server)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Role Tests

@Suite("RuntimeSource.Role")
struct RuntimeSourceRoleTests {
    @Test("client isClient")
    func clientIsClient() {
        #expect(RuntimeSource.Role.client.isClient == true)
        #expect(RuntimeSource.Role.client.isServer == false)
    }

    @Test("server isServer")
    func serverIsServer() {
        #expect(RuntimeSource.Role.server.isServer == true)
        #expect(RuntimeSource.Role.server.isClient == false)
    }

    @Test("Equatable")
    func equatable() {
        #expect(RuntimeSource.Role.client == .client)
        #expect(RuntimeSource.Role.server == .server)
        #expect(RuntimeSource.Role.client != .server)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let data = try JSONEncoder().encode(RuntimeSource.Role.server)
        let decoded = try JSONDecoder().decode(RuntimeSource.Role.self, from: data)
        #expect(decoded == .server)
    }
}

// MARK: - Identifier Tests

@Suite("RuntimeSource.Identifier")
struct RuntimeSourceIdentifierTests {
    @Test("rawValue init")
    func rawValueInit() {
        let id = RuntimeSource.Identifier(rawValue: "test.id")
        #expect(id.rawValue == "test.id")
    }

    @Test("string literal init")
    func stringLiteralInit() {
        let id: RuntimeSource.Identifier = "literal.id"
        #expect(id.rawValue == "literal.id")
    }

    @Test("Equatable and Hashable")
    func equatableHashable() {
        let a: RuntimeSource.Identifier = "same"
        let b = RuntimeSource.Identifier(rawValue: "same")
        let c: RuntimeSource.Identifier = "different"
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original: RuntimeSource.Identifier = "my.identifier"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeSource.Identifier.self, from: data)
        #expect(decoded == original)
    }
}
