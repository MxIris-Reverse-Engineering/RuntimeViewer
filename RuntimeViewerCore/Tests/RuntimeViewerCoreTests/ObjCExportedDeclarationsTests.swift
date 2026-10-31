import Foundation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// Public, so an exported symbol of this bundle publishes its class object.
/// Its stored properties are Objective-C ivars too.
public final class ObjCExportPublicFixture: NSObject {
    public var publicIvarFixture = 0
    private var privateIvarFixture = 0
}

/// Private, so no exported symbol publishes its class object.
private final class ObjCExportPrivateFixture: NSObject {
    var ivarOfPrivateFixture = 0
}

/// A pure Swift class — its root is `Swift._SwiftObject` — is in the
/// Objective-C class list too, and has no `_OBJC_CLASS_$_` symbol even when
/// it is public: the case a verdict by symbol name gets wrong.
public final class ObjCExportPublicSwiftRootFixture {
    public init() {}
}

private final class ObjCExportPrivateSwiftRootFixture {}

// MARK: - Tests

/// Which Objective-C classes an image does not export, and what Print
/// Exported Declarations Only makes of it — anchored on the fixtures above,
/// so nothing depends on what a system version ships. Whether a class is
/// exported is MachOObjCSection's verdict on its class object; these check
/// that the engine passes it on and prints by it.
@Suite(.serialized)
struct ObjCExportedDeclarationsTests {
    /// This test bundle's image, where every fixture is declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    /// One engine for the suite, and every object it lists for this bundle:
    /// the Swift entries are where the agreement test finds the other face of
    /// a Swift class.
    private static let sharedBundle = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "ObjCExportedDeclarationsTests")
        try await engine.connect()
        let objects = try await engine.objects(in: testBundlePath)
        return (engine, objects)
    }

    // MARK: - The sidebar's flag

    @Test("a class the bundle does not export is marked Not Exported in the Objective-C list, and one it exports is not", arguments: [
        ("ObjCExportPrivateFixture", true),
        ("ObjCExportPublicFixture", false),
        ("ObjCExportPrivateSwiftRootFixture", true),
        ("ObjCExportPublicSwiftRootFixture", false),
    ])
    func flagFollowsTheClassObject(name: String, isNotExported: Bool) async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.objcClass(named: name, in: objects), "\(name) is not listed")

        #expect(entry.properties.contains(.isNotExported) == isNotExported, "\(entry.name)")
    }

    /// Neither has a symbol of its own to judge — not even the private
    /// `@objc` protocol `SwiftDeclaredObjCProtocolListTests` declares, listed
    /// under its mangled name, nor this bundle's categories on Foundation's
    /// classes.
    @Test("no Objective-C protocol or category entry is marked")
    func protocolsAndCategoriesAreNotMarked() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let unjudgedEntries = objects.filter { $0.kind == .objc(.type(.protocol)) || $0.kind == .objc(.category(.class)) }

        #expect(unjudgedEntries.contains { $0.name.contains("SwiftDeclaredObjCProtocolPrivateFixture") }, "\(unjudgedEntries.map(\.name))")
        #expect(unjudgedEntries.contains { $0.kind == .objc(.category(.class)) }, "\(unjudgedEntries.map(\.name))")
        for entry in unjudgedEntries {
            #expect(!entry.properties.contains(.isNotExported), "\(entry.kind) \(entry.name)")
        }
    }

    /// MachOObjCSection judges a Swift class's Objective-C entry by its class
    /// object, MachOSwiftSection its Swift entry by its descriptor. Over every
    /// Swift class of this bundle — the dependencies it links statically
    /// included — the two verdicts mark the same classes.
    @Test("a Swift class is marked in the Objective-C list exactly when it is marked in the Swift list")
    func bothFacesOfASwiftClassAgree() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let swiftClassEntries = objects.filter { $0.kind == .objc(.type(.class)) && $0.properties.contains(.isSwiftClass) }

        var comparedCount = 0
        var markedCount = 0
        var disagreements: [String] = []
        for objcEntry in swiftClassEntries {
            guard let swiftEntry = try await engine.counterpart(for: objcEntry) else { continue }
            comparedCount += 1
            let isMarkedInObjCList = objcEntry.properties.contains(.isNotExported)
            if isMarkedInObjCList {
                markedCount += 1
            }
            if isMarkedInObjCList != swiftEntry.properties.contains(.isNotExported) {
                disagreements.append("\(objcEntry.name) (Objective-C list: \(isMarkedInObjCList))")
            }
        }

        #expect(comparedCount >= 4, "only \(comparedCount) of \(swiftClassEntries.count) Swift classes have a Swift entry")
        #expect(markedCount >= 2 && markedCount < comparedCount, "\(markedCount) of \(comparedCount) marked")
        #expect(disagreements.isEmpty, "\(disagreements.count) of \(comparedCount) disagree: \(disagreements)")
    }

    // MARK: - Helpers

    /// A Swift class's Objective-C name is mangled, and ends with the class's
    /// own name after its length.
    private static func objcClass(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        objects.first { $0.kind == .objc(.type(.class)) && ($0.name == name || $0.name.hasSuffix("\(name.count)\(name)")) }
    }
}
