import Testing
import Foundation
@testable import RuntimeViewerCore

/// Generated Interface (evolution proposal `objc-generated-interface`): an Objective-C class,
/// category or protocol asked for as Swift imports it — on the wire, where a peer of an earlier
/// build must keep working, and from an engine reading AppKit in this process.
@Suite("Generated Interface", .serialized)
struct GeneratedInterfaceTests {
    private struct MissingObject: Error {
        let description: String
    }

    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    /// One engine for the suite, with AppKit loaded, and the objects it lists.
    private static let shared = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "GeneratedInterfaceTests")
        try await engine.connect()
        try await engine.loadImage(at: appKitPath)
        return (engine, try await engine.objects(in: appKitPath))
    }

    /// The defaults every field of the options falls back to, as a request with nothing set sends.
    private static func defaultOptions(interfaceLanguage: RuntimeInterfaceLanguage? = nil) throws -> RuntimeObjectInterface.GenerationOptions {
        var options = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: Data("{}".utf8))
        options.interfaceLanguage = interfaceLanguage
        return options
    }

    private static func object(_ isWanted: (RuntimeObject) -> Bool) async throws -> (engine: RuntimeEngine, object: RuntimeObject) {
        let (engine, objects) = try await shared.value
        guard let object = objects.first(where: isWanted) else {
            throw MissingObject(description: "AppKit lists no such object")
        }
        return (engine, object)
    }

    // MARK: - On the wire

    @Test("a language is a bare string, and one this build does not know still decodes")
    func languageIsAString() throws {
        #expect(String(decoding: try JSONEncoder().encode(RuntimeInterfaceLanguage.swift), as: UTF8.self) == #""swift""#)
        let unknown = try JSONDecoder().decode(RuntimeInterfaceLanguage.self, from: Data(#""kotlin""#.utf8))
        #expect(unknown.rawValue == "kotlin")
        #expect(unknown != .swift)
        #expect(unknown != .objectiveC)
    }

    @Test("options from a build that predates the language ask for the object's own, and the language keys the cache")
    func optionsWithoutTheLanguage() throws {
        let savedOptions = try Self.defaultOptions()
        #expect(savedOptions.interfaceLanguage == nil)
        let swiftOptions = try Self.defaultOptions(interfaceLanguage: .swift)
        let decodedSwiftOptions = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: JSONEncoder().encode(swiftOptions))
        #expect(decodedSwiftOptions.interfaceLanguage == .swift)
        // `RuntimeInterfaceCache` keys by the options.
        #expect(swiftOptions != savedOptions)
        #expect(swiftOptions.hashValue != savedOptions.hashValue)
    }

    // MARK: - From the engine

    @Test("a class asked for in Swift is the class as Swift imports it")
    func classInSwift() async throws {
        let (engine, color) = try await Self.object { $0.kind == .objc(.type(.class)) && $0.name == "NSColor" }
        let interface = try #require(try await engine.interface(for: color, options: Self.defaultOptions(interfaceLanguage: .swift)))
        let text = interface.interfaceString.string
        #expect(interface.interfaceLanguage == .swift)
        #expect(text.contains("class NSColor: __C.NSObject"), "\(text.prefix(2000))")
        // A factory method restating the class name is an initializer.
        #expect(text.contains("convenience init!(red: Swift.Double, green: Swift.Double, blue: Swift.Double, alpha: Swift.Double)"), "\(text.prefix(2000))")
        #expect(!text.contains("@interface"), "\(text.prefix(2000))")
    }

    @Test("the same class asked for in nothing in particular is its header, and says so")
    func classInItsOwnLanguage() async throws {
        let (engine, color) = try await Self.object { $0.kind == .objc(.type(.class)) && $0.name == "NSColor" }
        let interface = try #require(try await engine.interface(for: color, options: Self.defaultOptions()))
        #expect(interface.interfaceLanguage == .objectiveC)
        #expect(interface.interfaceString.string.contains("@interface NSColor"))
    }

    @Test("a protocol asked for in Swift is the protocol as Swift imports it")
    func protocolInSwift() async throws {
        let (engine, dataSource) = try await Self.object { $0.kind == .objc(.type(.protocol)) && $0.name == "NSTableViewDataSource" }
        let interface = try #require(try await engine.interface(for: dataSource, options: Self.defaultOptions(interfaceLanguage: .swift)))
        #expect(interface.interfaceLanguage == .swift)
        #expect(interface.interfaceString.string.contains("protocol NSTableViewDataSource"), "\(interface.interfaceString.string.prefix(2000))")
    }

    @Test("a category asked for in Swift is an extension of its class")
    func categoryInSwift() async throws {
        let (engine, category) = try await Self.object { $0.kind == .objc(.category(.class)) && $0.name == "CIColor(NSAppKitAdditions)" }
        let interface = try #require(try await engine.interface(for: category, options: Self.defaultOptions(interfaceLanguage: .swift)))
        let text = interface.interfaceString.string
        #expect(interface.interfaceLanguage == .swift)
        #expect(text.contains("extension __C.CIColor"), "\(text)")
        #expect(text.contains("The Objective-C category CIColor(NSAppKitAdditions)."), "\(text)")
    }

    /// What a client of this build reads from a server that predates the language: the key is not
    /// there, so the client can tell it got the header rather than what it asked for.
    @Test("an interface from a peer that predates the language has none")
    func interfaceWithoutTheLanguage() async throws {
        let (engine, color) = try await Self.object { $0.kind == .objc(.type(.class)) && $0.name == "NSColor" }
        let interface = try #require(try await engine.interface(for: color, options: Self.defaultOptions()))
        var jsonObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(interface)) as? [String: Any])
        #expect(jsonObject["interfaceLanguage"] as? String == "occ")
        jsonObject.removeValue(forKey: "interfaceLanguage")
        let decoded = try JSONDecoder().decode(RuntimeObjectInterface.self, from: JSONSerialization.data(withJSONObject: jsonObject))
        #expect(decoded.interfaceLanguage == nil)
        #expect(decoded.interfaceString.string == interface.interfaceString.string)
    }
}
