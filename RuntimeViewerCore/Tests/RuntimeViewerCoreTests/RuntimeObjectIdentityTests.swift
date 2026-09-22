import Foundation
import OrderedCollections
import RuntimeViewerCore
import Testing

/// What `RuntimeObject`'s `==`, `hash(into:)` and `id` actually mean, pinned at
/// the seam a caller sees.
///
/// Written as a characterization suite *before* the identity change in the
/// proposal `draft-runtime-object-identity`: at this point every assertion
/// below states the pre-change behaviour, including the parts that proposal
/// calls defects. Assertions that have to flip are flipped explicitly, one at a
/// time, with the reason recorded in the proposal's decision log — never
/// deleted.
@Suite("RuntimeObject identity")
struct RuntimeObjectIdentityTests {
    private static let imagePath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static func object(
        name: String = "NSView",
        displayName: String? = nil,
        kind: RuntimeObjectKind = .objc(.type(.class)),
        imagePath: String = imagePath,
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName ?? name,
            kind: kind,
            imagePath: imagePath,
            children: children,
            properties: properties
        )
    }

    // MARK: - The three fields RuntimeObjectKey excludes

    @Test("two objects differing only in displayName are not equal")
    func displayNameParticipatesInEquality() {
        let printedPlainly = Self.object(displayName: "NSView")
        let printedQualified = Self.object(displayName: "AppKit.NSView")

        #expect(printedPlainly != printedQualified)
        #expect(Set([printedPlainly, printedQualified]).count == 2)
    }

    @Test("two objects differing only in children are not equal")
    func childrenParticipateInEquality() {
        let childless = Self.object()
        let withChild = Self.object(children: [Self.object(name: "NSView.Inner")])

        #expect(childless != withChild)
        #expect(Set([childless, withChild]).count == 2)
    }

    @Test("two objects differing only in properties are not equal")
    func propertiesParticipateInEquality() {
        let unmarked = Self.object()
        let bridged = Self.object(properties: [.isSwiftClass])

        #expect(unmarked != bridged)
        #expect(Set([unmarked, bridged]).count == 2)
    }

    /// The three above are exactly the fields `RuntimeObjectKey` drops, which is
    /// why every one of them can make a lookup keyed on the whole object miss
    /// while the key-based one hits.
    @Test("RuntimeObjectKey is blind to all three")
    func keyIgnoresTheThreeFields() {
        let plain = Self.object()
        let decorated = Self.object(
            displayName: "AppKit.NSView",
            children: [Self.object(name: "NSView.Inner")],
            properties: [.isSwiftClass]
        )

        #expect(plain.key == decorated.key)
        #expect(plain != decorated)
    }

    // MARK: - The fields that name the type

    @Test("objects differing in name, kind or imagePath are never equal", arguments: [
        ("name", RuntimeObjectIdentityTests.object(name: "NSWindow")),
        ("kind", RuntimeObjectIdentityTests.object(kind: .objc(.type(.protocol)))),
        ("imagePath", RuntimeObjectIdentityTests.object(imagePath: "/usr/lib/libobjc.A.dylib")),
    ])
    func identityFieldsParticipateInEquality(field: String, other: RuntimeObject) {
        #expect(Self.object() != other, "objects differing in \(field) must not be equal")
        #expect(Self.object().key != other.key)
    }

    // MARK: - Derived operations

    @Test("withAppendedChild produces an object unequal to the original")
    func appendingAChildBreaksEquality() {
        let parent = Self.object(name: "Box", kind: .swift(.type(.struct)))
        let grown = parent.withAppendedChild(Self.object(name: "Box.Int", kind: .swift(.type(.struct))))

        #expect(parent != grown)
        #expect(parent.key == grown.key)
    }

    @Test("withImagePath produces an object unequal to the original")
    func rehomingBreaksEquality() {
        let original = Self.object()
        let rehomed = original.withImagePath("/usr/lib/libobjc.A.dylib")

        #expect(original != rehomed)
        #expect(original.key != rehomed.key)
    }

    @Test("id is the object itself")
    func identifiableIDIsSelf() {
        let object = Self.object()

        #expect(object.id == object)
    }

    // MARK: - Hashing agrees with equality

    /// Not a restatement of `==`: `Set` needs `hash(into:)` and `==` to agree,
    /// so this is what catches one of them being changed without the other.
    @Test("objects equal under == collapse to one element in a Set")
    func equalObjectsCollapseInASet() {
        let first = Self.object(children: [Self.object(name: "NSView.Inner")], properties: [.isGeneric])
        let second = Self.object(children: [Self.object(name: "NSView.Inner")], properties: [.isGeneric])

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    // MARK: - Containers and derived conformances

    /// `RuntimeRelationshipsResolver` collects subclasses and conformers into
    /// an `OrderedSet`, so whatever `==` and `hash(into:)` say is what
    /// deduplicates a relationship list.
    @Test("an OrderedSet deduplicates by the same rule as ==")
    func orderedSetFollowsEquality() {
        var collected: OrderedSet<RuntimeObject> = []
        collected.append(Self.object())
        collected.append(Self.object(properties: [.isSwiftClass]))
        collected.append(Self.object())

        #expect(collected.count == 2)
    }

    /// `RuntimeObjectBookmark`'s `Hashable` is compiler-synthesized from its
    /// single `RuntimeObject` field, so a bookmark inherits whatever the object
    /// says about identity.
    @Test("a bookmark inherits the object's equality")
    func bookmarkInheritsObjectEquality() {
        let plain = RuntimeObjectBookmark(object: Self.object())
        let bridged = RuntimeObjectBookmark(object: Self.object(properties: [.isSwiftClass]))

        #expect(plain != bridged)
        #expect(Set([plain, bridged]).count == 2)
    }
}
