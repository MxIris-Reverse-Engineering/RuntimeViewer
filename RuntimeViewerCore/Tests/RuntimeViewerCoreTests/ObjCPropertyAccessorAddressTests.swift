import Testing
import Foundation
import RuntimeViewerCore

/// Regression coverage for the accessor lookup behind
/// `RuntimeEngine.memberAddresses(for:memberName:)`.
///
/// A property's accessor address was looked up by selector in a single table
/// built from the instance methods and the class methods together. A class
/// method sharing a selector with an instance method therefore overwrote it,
/// and every instance property whose getter had a same-named class method
/// reported the *class* method's address while still printing the instance
/// method's symbol. `NSObject` alone hits it four times: `description`,
/// `debugDescription`, `hash` and `superclass` each exist as both `-` and `+`.
///
/// MachOObjCSection does not have this bug — its rendering context keeps
/// `methodIMPs` and `classMethodIMPs` apart and picks between them by
/// `isClassProperty`, so the interface text was right while `memberAddresses`
/// was wrong about the same property. This is the same shape as the
/// synthesized-setter strip that MachOObjCSection fixed in `0.8.104`: where
/// RuntimeViewer keeps its own second copy of upstream logic, that copy is the
/// one that drifts. See `ObjCSynthesizedMethodStrippingTests`.
///
/// Both tests derive their expectations from the image rather than naming
/// addresses, so an OS update cannot make them stale.
@Suite("ObjC Property Accessor Addresses")
struct ObjCPropertyAccessorAddressTests {
    /// Small, always present, and it declares the colliding selectors the bug
    /// needs.
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    private static func makeEngine() async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-objc-property-accessor-addresses")
        try await engine.connect()
        try await engine.loadImage(at: libobjcPath)
        return engine
    }

    private static func classObjects(in engine: RuntimeEngine) async throws -> [RuntimeObject] {
        let objects = try await engine.objects(in: libobjcPath)
        return objects
            .filter { $0.kind == .objc(.type(.class)) }
            .sorted { $0.name < $1.name }
    }

    /// The invariant the bug breaks: a member address row carries the symbol it
    /// belongs to, so two rows naming the same symbol cannot report different
    /// addresses. Before the fix a property getter row said
    /// `-[NSObject description]` and gave `+[NSObject description]`'s address,
    /// contradicting the instance-method row right above it.
    @Test("One symbol never has two addresses")
    func oneSymbolNeverHasTwoAddresses() async throws {
        let engine = try await Self.makeEngine()
        var addressesBySymbol: [String: (address: String, kind: String)] = [:]
        var comparedSymbolCount = 0

        for object in try await Self.classObjects(in: engine) {
            for member in try await engine.memberAddresses(for: object, memberName: nil) {
                guard let existing = addressesBySymbol[member.symbolName] else {
                    addressesBySymbol[member.symbolName] = (member.address, member.kind)
                    continue
                }
                comparedSymbolCount += 1
                #expect(
                    existing.address == member.address,
                    """
                    \(member.symbolName) is reported at two addresses: \
                    \(existing.address) as '\(existing.kind)' and \(member.address) as '\(member.kind)'.
                    """
                )
            }
        }

        #expect(comparedSymbolCount > 0, "No symbol appeared twice, so this test proved nothing")
    }

    /// The specific collision, spelled out: an instance property's getter must
    /// resolve to the instance method, never to the class method of the same
    /// name. Skips the property when the image gives both the same address,
    /// which would make the two indistinguishable.
    @Test("An instance property's getter is the instance method, not the same-named class method")
    func instancePropertyGetterIsNotTheClassMethod() async throws {
        let engine = try await Self.makeEngine()
        let classObjects = try await Self.classObjects(in: engine)
        let nsObject = try #require(
            classObjects.first { $0.name == "NSObject" },
            "libobjc no longer declares NSObject"
        )

        let members = try await engine.memberAddresses(for: nsObject, memberName: nil)
        func address(ofKind kind: String, named name: String) -> String? {
            members.first { $0.kind == kind && $0.name == name }?.address
        }

        var checkedPropertyCount = 0
        for getter in members where getter.kind == "property getter" {
            guard let instanceMethodAddress = address(ofKind: "method", named: getter.name),
                  let classMethodAddress = address(ofKind: "class method", named: getter.name),
                  instanceMethodAddress != classMethodAddress
            else { continue }

            checkedPropertyCount += 1
            #expect(
                getter.address == instanceMethodAddress,
                """
                The getter of instance property '\(getter.name)' resolved to \(getter.address); \
                -[NSObject \(getter.name)] is at \(instanceMethodAddress) and \
                +[NSObject \(getter.name)] at \(classMethodAddress).
                """
            )
        }

        #expect(
            checkedPropertyCount > 0,
            "NSObject no longer declares an instance property whose getter collides with a class method"
        )
    }
}
