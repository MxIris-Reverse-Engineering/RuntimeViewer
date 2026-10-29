import Foundation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// Renamed with `@objc(…)` to its own Swift name, the way Xcode's frameworks
/// write it (`@objc(DVTActorProtocol) protocol DVTActorProtocol`), so
/// MachOSwiftSection pairs the declaration with its record by that name.
@objc(SwiftDeclaredObjCProtocolSameNameFixture)
protocol SwiftDeclaredObjCProtocolSameNameFixture {
    func sameNameRequirement()
}

/// An `@objc` protocol whose extension adds a member only Swift sees.
@objc
protocol SwiftDeclaredObjCProtocolExtendedFixture {
    func extendedRequirement()
}

extension SwiftDeclaredObjCProtocolExtendedFixture {
    func extensionMemberOfObjCProtocolFixture() {}
}

/// A class of this bundle adopting an imported Objective-C protocol, which
/// no conformance record names: an Objective-C protocol has no witness table.
final class SwiftDeclaredObjCProtocolCopyingFixture: NSObject, NSCopying {
    func copy(with zone: NSZone? = nil) -> Any { self }
}

/// Adopted by an extension of a Foundation class, which the compiler records
/// in a category of that class.
@objc
protocol SwiftDeclaredObjCProtocolCategoryFixture {
    func categoryRequirementFixture()
}

extension ByteCountFormatter: SwiftDeclaredObjCProtocolCategoryFixture {
    func categoryRequirementFixture() {}
}

/// Adopted beside a Swift protocol in one extension of a Foundation class:
/// the Swift protocol gets a conformance record, this one a category.
@objc
protocol SwiftDeclaredObjCProtocolBesideSwiftConformanceFixture {
    func besideSwiftConformanceRequirementFixture()
}

protocol SwiftOnlyConformanceFixture {}

extension DateComponentsFormatter: SwiftOnlyConformanceFixture, SwiftDeclaredObjCProtocolBesideSwiftConformanceFixture {
    func besideSwiftConformanceRequirementFixture() {}
}

/// The `@objc` protocols a Swift image declares, listed and printed on the
/// Swift side from MachOSwiftSection's `objcProtocolDefinitions`, and the
/// Objective-C protocols the image's classes adopt, printed where Swift
/// shows a type's conformances.
///
/// Anchored on the protocols this test bundle declares — the two
/// `SwiftDefinedObjCProtocolTests` declares and the ones above — so nothing
/// depends on what a system version ships.
@Suite(.serialized)
struct SwiftDeclaredObjCProtocolListTests {
    /// This test bundle's image, where every fixture is declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    /// One engine for the suite, and the Swift objects it lists for this
    /// bundle.
    private static let sharedBundle = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "SwiftDeclaredObjCProtocolListTests")
        try await engine.connect()
        let objects = try await engine.objects(in: testBundlePath)
        return (engine, objects.filter(\.kind.isSwift))
    }

    private static let options = RuntimeObjectInterface.GenerationOptions(
        objcHeaderOptions: .default,
        swiftInterfaceOptions: .default,
        transformer: .default
    )

    // MARK: - Listing

    @Test("the Swift list lists the @objc protocols this bundle declares", arguments: [
        "MangledSwiftObjCProtocolFixture",
        "RenamedSwiftObjCProtocolFixture",
        "SwiftDeclaredObjCProtocolSameNameFixture",
        "SwiftDeclaredObjCProtocolExtendedFixture",
    ])
    func swiftListListsTheProtocol(protocolName: String) async throws {
        let (_, objects) = try await Self.sharedBundle.value
        try #require(Self.protocolEntry(named: protocolName, in: objects) != nil, "\(protocolName) is not listed")
    }

    @Test("an @objc protocol's extension prints with it and has no entry of its own")
    func extensionPrintsWithTheProtocol() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let interface = try await Self.interfaceText(ofProtocolNamed: "SwiftDeclaredObjCProtocolExtendedFixture")

        // Once: MachOSwiftSection prints the extension after the protocol, so
        // the section must not append it again.
        #expect(interface.components(separatedBy: "extensionMemberOfObjCProtocolFixture").count - 1 == 1, "\(interface)")
        #expect(!objects.contains { $0.kind == .swift(.extension(.protocol)) && $0.displayName.hasSuffix("SwiftDeclaredObjCProtocolExtendedFixture") })
    }

    // MARK: - Printing

    @Test("an @objc protocol prints as one, with its requirements")
    func protocolPrintsWithItsRequirements() async throws {
        let interface = try await Self.interfaceText(ofProtocolNamed: "MangledSwiftObjCProtocolFixture")

        #expect(interface.contains("@objc protocol MangledSwiftObjCProtocolFixture"))
        #expect(interface.contains("func mangledRequirement()"))
    }

    @Test("a protocol renamed to its own name prints the runtime name it was given")
    func sameNameRenamedProtocolPrintsItsRuntimeName() async throws {
        let interface = try await Self.interfaceText(ofProtocolNamed: "SwiftDeclaredObjCProtocolSameNameFixture")

        #expect(interface.contains("@objc(SwiftDeclaredObjCProtocolSameNameFixture) protocol SwiftDeclaredObjCProtocolSameNameFixture"))
        #expect(interface.contains("func sameNameRequirement()"))
    }

    /// `@objc(RuntimeViewerCoreTestsRenamedSwiftProtocol)` names nothing the
    /// declaration can be paired with, so MachOSwiftSection prints it without
    /// requirements and says why.
    @Test("a protocol renamed to another name prints though no record pairs with it")
    func renamedProtocolWithoutARecordPrints() async throws {
        let interface = try await Self.interfaceText(ofProtocolNamed: "RenamedSwiftObjCProtocolFixture")

        #expect(interface.contains("protocol RenamedSwiftObjCProtocolFixture"))
        #expect(interface.contains("No Objective-C protocol record pairs with this declaration"))
    }

    @Test("a class's declaration names the Objective-C protocols it adopts")
    func classDeclarationNamesItsObjCProtocols() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let classEntry = try #require(objects.first { $0.kind == .swift(.type(.class)) && $0.displayName.hasSuffix("SwiftDeclaredObjCProtocolCopyingFixture") })
        let interface = try await Self.interfaceText(of: classEntry)

        let declarationLine = try #require(interface.split(separator: "\n").first { $0.contains("class SwiftDeclaredObjCProtocolCopyingFixture") })
        #expect(declarationLine.contains("NSCopying"), "\(declarationLine)")
    }

    @Test("an extension of another module's class adopting an @objc protocol is listed as a conformance")
    func categoryConformanceHasAnEntry() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entries = objects.filter { $0.kind == .swift(.conformance(.class)) && $0.displayName.contains("ByteCountFormatter") }
        let entry = try #require(entries.first, "no conformance entry for NSByteCountFormatter")
        #expect(entries.count == 1)

        let interface = try await Self.interfaceText(of: entry)
        #expect(interface.contains("SwiftDeclaredObjCProtocolCategoryFixture"))
    }

    @Test("a class's Objective-C and Swift conformances print in one entry")
    func categoryConformancePrintsBesideConformanceRecords() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entries = objects.filter { $0.kind == .swift(.conformance(.class)) && $0.displayName.contains("DateComponentsFormatter") }
        let entry = try #require(entries.first, "no conformance entry for NSDateComponentsFormatter")
        #expect(entries.count == 1)

        let interface = try await Self.interfaceText(of: entry)
        #expect(interface.contains("SwiftOnlyConformanceFixture"))
        #expect(interface.contains("SwiftDeclaredObjCProtocolBesideSwiftConformanceFixture"))
    }

    // MARK: - Find, member addresses and jumps

    @Test("Find lists an @objc protocol's requirements and default implementations as its members")
    func findListsRequirementsAndDefaultImplementations() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.protocolEntry(named: "SwiftDeclaredObjCProtocolExtendedFixture", in: objects))
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: entry.imagePath))

        let outcomes = try await section.corpusPrints(of: [entry], transformer: .default)
        guard case .printed(let corpusPrint) = try #require(outcomes.first) else {
            Issue.record("the protocol did not print for the corpus")
            return
        }
        let memberNames = corpusPrint.members.map(\.name)
        #expect(memberNames.contains { $0.hasPrefix("extendedRequirement") }, "\(memberNames)")
        #expect(memberNames.contains { $0.hasPrefix("extensionMemberOfObjCProtocolFixture") }, "\(memberNames)")
    }

    @Test("an @objc protocol's default implementations have addresses and its requirements none")
    func onlyDefaultImplementationsHaveAddresses() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.protocolEntry(named: "SwiftDeclaredObjCProtocolExtendedFixture", in: objects))
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: entry.imagePath))

        let addressedNames = try await section.memberAddresses(for: entry, memberName: nil).map(\.name)
        #expect(addressedNames.contains { $0.hasPrefix("extensionMemberOfObjCProtocolFixture") }, "\(addressedNames)")
        #expect(!addressedNames.contains { $0.hasPrefix("extendedRequirement") }, "\(addressedNames)")
    }

    /// What the content pane asks for when a protocol's name is clicked in an
    /// interface of the image that declares it — a class declaration naming
    /// the protocols it adopts, say: the mangled name the interface carries,
    /// under the image of the object on screen
    /// (`FrozenSemanticString+ThemeProfile`).
    @Test("a reference to an @objc protocol lands on its entry")
    func referenceLandsOnTheEntry() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.protocolEntry(named: "MangledSwiftObjCProtocolFixture", in: objects))
        let reference = RuntimeObject(name: entry.name, displayName: "MangledSwiftObjCProtocolFixture", kind: .swift(.type(.protocol)), imagePath: entry.imagePath, children: [])

        let interface = try #require(try await engine.interface(for: reference, options: Self.options))
        #expect(interface.object == entry)
    }

    // MARK: - The two faces

    @Test("a protocol paired with its Objective-C record is marked as listed there too", arguments: [
        "MangledSwiftObjCProtocolFixture",
        "SwiftDeclaredObjCProtocolSameNameFixture",
    ])
    func pairedProtocolIsMarked(protocolName: String) async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.protocolEntry(named: protocolName, in: objects))

        #expect(entry.properties.contains(.isObjCProtocol))
    }

    @Test("a protocol renamed to another name pairs with no record and is not marked")
    func unpairedProtocolIsNotMarked() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.protocolEntry(named: "RenamedSwiftObjCProtocolFixture", in: objects))

        #expect(!entry.properties.contains(.isObjCProtocol))
    }

    @Test("an @objc protocol's two entries jump to each other", arguments: [
        ("MangledSwiftObjCProtocolFixture", "_TtP22RuntimeViewerCoreTests31MangledSwiftObjCProtocolFixture_"),
        ("SwiftDeclaredObjCProtocolSameNameFixture", "SwiftDeclaredObjCProtocolSameNameFixture"),
    ])
    func twoEntriesJumpToEachOther(protocolName: String, runtimeName: String) async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let swiftEntry = try #require(Self.protocolEntry(named: protocolName, in: objects))
        let objcEntry = try #require(try await Self.objcProtocolEntry(named: runtimeName))
        #expect(objcEntry.counterpartKind == .swiftProtocol)
        #expect(swiftEntry.counterpartKind == .objcProtocol)

        let swiftFace = try #require(try await engine.counterpart(for: objcEntry), "\(runtimeName) found no Swift face")
        #expect(swiftFace == swiftEntry)
        #expect(swiftFace.properties.contains(.isObjCProtocol))
        #expect(try await engine.counterpart(for: swiftEntry) == objcEntry)
    }

    /// The Objective-C entry is marked from its record alone, so it offers the
    /// jump; the engine has no Swift face to give for a declaration that pairs
    /// with no record.
    @Test("the Objective-C entry of a protocol no declaration pairs with finds no Swift face")
    func unpairedObjCEntryFindsNoSwiftFace() async throws {
        let (engine, _) = try await Self.sharedBundle.value
        let objcEntry = try #require(try await Self.objcProtocolEntry(named: "RuntimeViewerCoreTestsRenamedSwiftProtocol"))
        #expect(objcEntry.counterpartKind == .swiftProtocol)

        #expect(try await engine.counterpart(for: objcEntry) == nil)
    }

    @Test("an @objc protocol is one Type Relationships candidate, under its Objective-C entry")
    func protocolIsOneRelationshipCandidate() async throws {
        let (engine, _) = try await Self.sharedBundle.value
        let objcEntry = try #require(try await Self.objcProtocolEntry(named: "_TtP22RuntimeViewerCoreTests31MangledSwiftObjCProtocolFixture_"))

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "MangledSwiftObjCProtocolFixture", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true))
        #expect(trees.map(\.root) == [objcEntry], "\(trees.map { "\($0.root.kind) \($0.root.displayName)" })")
    }

    // MARK: - Helpers

    /// This bundle's Objective-C entry for the protocol record `runtimeName`.
    private static func objcProtocolEntry(named runtimeName: String) async throws -> RuntimeObject? {
        let (engine, _) = try await sharedBundle.value
        return try await engine.objects(in: testBundlePath).first { $0.kind == .objc(.type(.protocol)) && $0.name == runtimeName }
    }

    private static func protocolEntry(named protocolName: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        objects.first { $0.kind == .swift(.type(.protocol)) && ($0.displayName == protocolName || $0.displayName.hasSuffix(".\(protocolName)")) }
    }

    private static func interfaceText(ofProtocolNamed protocolName: String) async throws -> String {
        let (_, objects) = try await sharedBundle.value
        return try await interfaceText(of: try #require(protocolEntry(named: protocolName, in: objects), "\(protocolName) is not listed"))
    }

    private static func interfaceText(of object: RuntimeObject) async throws -> String {
        let (engine, _) = try await sharedBundle.value
        return try #require(try await engine.interface(for: object, options: options)).interfaceString.string
    }
}
