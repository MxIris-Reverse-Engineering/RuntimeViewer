import Testing
import Foundation
import RuntimeViewerCore

// MARK: - RuntimeObject Tests

@Suite("RuntimeObject")
struct RuntimeObjectTests {
    // MARK: - Initialization

    @Test("init sets all properties correctly")
    func initSetsAllProperties() {
        let child = RuntimeObject(
            name: "ChildClass",
            displayName: "ChildClass",
            kind: .swift(.type(.class)),
            secondaryKind: nil,
            imagePath: "/path/to/Framework",
            children: []
        )
        let object = RuntimeObject(
            name: "ParentClass",
            displayName: "ParentClass",
            kind: .objc(.type(.class)),
            secondaryKind: .swift(.type(.struct)),
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            children: [child]
        )

        #expect(object.name == "ParentClass")
        #expect(object.displayName == "ParentClass")
        #expect(object.kind == .objc(.type(.class)))
        #expect(object.secondaryKind == .swift(.type(.struct)))
        #expect(object.imagePath == "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
        #expect(object.children.count == 1)
        #expect(object.children[0].name == "ChildClass")
    }

    // MARK: - Identifiable

    @Test("id is self")
    func idIsSelf() {
        let object = RuntimeObject(
            name: "NSObject",
            displayName: "NSObject",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/usr/lib/libobjc.A.dylib",
            children: []
        )
        #expect(object.id == object)
    }

    // MARK: - imageName

    @Test("imageName extracts last path component without extension")
    func imageNameExtraction() {
        let object = RuntimeObject(
            name: "NSObject",
            displayName: "NSObject",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/usr/lib/libobjc.A.dylib",
            children: []
        )
        #expect(object.imageName == "libobjc.A")
    }

    @Test("imageName for framework path")
    func imageNameFrameworkPath() {
        let object = RuntimeObject(
            name: "NSView",
            displayName: "NSView",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            children: []
        )
        #expect(object.imageName == "AppKit")
    }

    // MARK: - withImagePath

    @Test("withImagePath creates new object with different path")
    func withImagePath() {
        let object = RuntimeObject(
            name: "NSObject",
            displayName: "NSObject",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/old/path",
            children: []
        )
        let newObject = object.withImagePath("/new/path")

        #expect(newObject.name == object.name)
        #expect(newObject.displayName == object.displayName)
        #expect(newObject.kind == object.kind)
        #expect(newObject.secondaryKind == object.secondaryKind)
        #expect(newObject.children == object.children)
        #expect(newObject.imagePath == "/new/path")
        #expect(newObject.imagePath != object.imagePath)
    }

    // MARK: - withAppendedChild

    @Test("withAppendedChild appends a single child onto an empty children array")
    func withAppendedChildOnEmpty() {
        let parent = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let child = RuntimeObject(name: "BoxOfInt", displayName: "BoxOfInt", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let updated = parent.withAppendedChild(child)
        #expect(updated.children.count == 1)
        #expect(updated.children[0] == child)
    }

    @Test("withAppendedChild accumulates when applied iteratively")
    func withAppendedChildAccumulates() {
        // Regression for the sidebar splice that previously appended every
        // specialized child onto the *original* parent payload, dropping any
        // earlier specializations. Re-binding through `withAppendedChild`
        // walks the latest object on each step, so two iterative appends
        // must yield two children.
        let parent = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let child1 = RuntimeObject(name: "BoxOfInt", displayName: "BoxOfInt", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let child2 = RuntimeObject(name: "BoxOfString", displayName: "BoxOfString", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let firstStep = parent.withAppendedChild(child1)
        let secondStep = firstStep.withAppendedChild(child2)
        #expect(secondStep.children.count == 2)
        #expect(secondStep.children[0] == child1)
        #expect(secondStep.children[1] == child2)
    }

    @Test("withAppendedChild preserves properties bitfield")
    func withAppendedChildPreservesProperties() {
        let parent = RuntimeObject(
            name: "Box",
            displayName: "Box",
            kind: .swift(.type(.struct)),
            secondaryKind: nil,
            imagePath: "/p",
            children: [],
            properties: [.isGeneric]
        )
        let child = RuntimeObject(name: "BoxOfInt", displayName: "BoxOfInt", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [], properties: [.isSpecialized])
        let updated = parent.withAppendedChild(child)
        #expect(updated.properties.contains(.isGeneric))
        #expect(updated.children[0].properties.contains(.isSpecialized))
    }

    // MARK: - RuntimeObjectKey

    @Test("RuntimeObjectKey ignores children differences")
    func runtimeObjectKeyIgnoresChildren() {
        // The sidebar splice relies on `RuntimeObjectKey` staying stable
        // across `withAppendedChild` so the cell viewmodel can be located
        // before *and* after a child has been spliced in. Bake that
        // invariant into the test suite.
        let bare = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let child = RuntimeObject(name: "BoxOfInt", displayName: "BoxOfInt", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let withChild = bare.withAppendedChild(child)
        #expect(bare.key == withChild.key)
    }

    @Test("RuntimeObjectKey distinguishes by imagePath / name / kind")
    func runtimeObjectKeyDiscriminates() {
        let a = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let differentImage = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/q", children: [])
        let differentName = RuntimeObject(name: "BoxOfInt", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let differentKind = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.class)), secondaryKind: nil, imagePath: "/p", children: [])

        #expect(a.key != differentImage.key)
        #expect(a.key != differentName.key)
        #expect(a.key != differentKind.key)
    }

    @Test("RuntimeObjectKey-keyed Set acts as a dedup oracle for accumulated children")
    func runtimeObjectKeyDedup() {
        // Mirrors the sidebar's de-dup guard:
        //   guard !currentParent.children.contains(where: { $0.key == child.key }) else { return }
        // A re-broadcast event must not insert the same specialized child
        // twice — the test asserts that walking by key catches the dup.
        let parent = RuntimeObject(name: "Box", displayName: "Box", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        let child = RuntimeObject(name: "BoxOfInt", displayName: "BoxOfInt", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        var current = parent.withAppendedChild(child)
        // Simulate a duplicate broadcast: skip when key already present.
        if !current.children.contains(where: { $0.key == child.key }) {
            current = current.withAppendedChild(child)
        }
        #expect(current.children.count == 1)
    }

    // MARK: - Equatable

    @Test("objects with same properties are equal")
    func equality() {
        let a = RuntimeObject(name: "A", displayName: "A", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        let b = RuntimeObject(name: "A", displayName: "A", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(a == b)
    }

    @Test("objects with different names are not equal")
    func inequalityByName() {
        let a = RuntimeObject(name: "A", displayName: "A", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        let b = RuntimeObject(name: "B", displayName: "A", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(a != b)
    }

    // MARK: - Hashable

    @Test("equal objects have same hash")
    func hashConsistency() {
        let a = RuntimeObject(name: "X", displayName: "X", kind: .swift(.type(.enum)), secondaryKind: nil, imagePath: "/p", children: [])
        let b = RuntimeObject(name: "X", displayName: "X", kind: .swift(.type(.enum)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(a.hashValue == b.hashValue)
    }

    @Test("objects can be stored in Set")
    func setStorage() {
        let a = RuntimeObject(name: "A", displayName: "A", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        let b = RuntimeObject(name: "B", displayName: "B", kind: .c(.union), secondaryKind: nil, imagePath: "/p", children: [])
        let set: Set<RuntimeObject> = [a, b, a]
        #expect(set.count == 2)
    }

    // MARK: - Comparable

    @Test("objects are sorted by imagePath, kind, then displayName")
    func sorting() {
        let objcClass = RuntimeObject(name: "B", displayName: "B", kind: .objc(.type(.class)), secondaryKind: nil, imagePath: "/a", children: [])
        let swiftStruct = RuntimeObject(name: "A", displayName: "A", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/a", children: [])
        let cStruct = RuntimeObject(name: "C", displayName: "C", kind: .c(.struct), secondaryKind: nil, imagePath: "/a", children: [])

        let sorted = [swiftStruct, objcClass, cStruct].sorted()
        // C (level 0) < ObjC Class (level 2) < Swift Struct (level 7)
        #expect(sorted[0].name == "C")
        #expect(sorted[1].name == "B")
        #expect(sorted[2].name == "A")
    }

    // MARK: - Codable

    @Test("encodes and decodes correctly")
    func codable() throws {
        let original = RuntimeObject(
            name: "NSView",
            displayName: "NSView",
            kind: .objc(.type(.class)),
            secondaryKind: .swift(.extension(.class)),
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            children: [
                RuntimeObject(name: "Child", displayName: "Child", kind: .c(.struct), secondaryKind: nil, imagePath: "/path", children: []),
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RuntimeObject.self, from: data)

        #expect(decoded == original)
        #expect(decoded.name == "NSView")
        #expect(decoded.secondaryKind == RuntimeObjectKind.swift(.extension(.class)))
        #expect(decoded.children.count == 1)
    }

    // MARK: - exportFileName

    @Test("Swift type export produces .swiftinterface extension")
    func exportFileNameSwiftType() {
        let object = RuntimeObject(name: "MyStruct", displayName: "MyStruct", kind: .swift(.type(.struct)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "MyStruct.swiftinterface")
    }

    @Test("Swift extension export includes +Extension suffix")
    func exportFileNameSwiftExtension() {
        let object = RuntimeObject(name: "MyClass", displayName: "MyClass", kind: .swift(.extension(.class)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "MyClass+Extension.swiftinterface")
    }

    @Test("Swift conformance export includes +Conformance suffix")
    func exportFileNameSwiftConformance() {
        let object = RuntimeObject(name: "MyEnum", displayName: "MyEnum", kind: .swift(.conformance(.enum)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "MyEnum+Conformance.swiftinterface")
    }

    @Test("ObjC class export produces .h extension")
    func exportFileNameObjCClass() {
        let object = RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "NSObject.h")
    }

    @Test("ObjC protocol export produces -Protocol.h extension")
    func exportFileNameObjCProtocol() {
        let object = RuntimeObject(name: "NSCoding", displayName: "NSCoding", kind: .objc(.type(.protocol)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "NSCoding-Protocol.h")
    }

    @Test("C struct export produces .h extension")
    func exportFileNameCStruct() {
        let object = RuntimeObject(name: "CGRect", displayName: "CGRect", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "CGRect.h")
    }

    @Test("ObjC category export uses +CategoryName.h format")
    func exportFileNameObjCCategory() {
        let object = RuntimeObject(name: "NSObject(MyCategory)", displayName: "NSObject(MyCategory)", kind: .objc(.category(.class)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "NSObject+MyCategory.h")
    }

    @Test("exportFileName sanitizes slashes and colons")
    func exportFileNameSanitization() {
        let object = RuntimeObject(name: "NS/Obj:ect", displayName: "NS/Obj:ect", kind: .objc(.type(.class)), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "NS_Obj_ect.h")
    }

    @Test("exportFileName sanitizes C++ template angle brackets")
    func exportFileNameCppTemplateSanitization() {
        let object = RuntimeObject(name: "std::vector<std::pair<int, float>>", displayName: "std::vector<std::pair<int, float>>", kind: .c(.struct), secondaryKind: nil, imagePath: "/p", children: [])
        #expect(object.exportFileName == "std__vector_std__pair_int, float__.h")
    }
}

// MARK: - RuntimeObjectKind Tests

@Suite("RuntimeObjectKind")
struct RuntimeObjectKindTests {
    // MARK: - isC / isObjC / isSwift

    @Test("isC returns true only for C kinds")
    func isCProperty() {
        #expect(RuntimeObjectKind.c(.struct).isC == true)
        #expect(RuntimeObjectKind.c(.union).isC == true)
        #expect(RuntimeObjectKind.objc(.type(.class)).isC == false)
        #expect(RuntimeObjectKind.swift(.type(.class)).isC == false)
    }

    @Test("isObjC returns true only for ObjC kinds")
    func isObjCProperty() {
        #expect(RuntimeObjectKind.objc(.type(.class)).isObjC == true)
        #expect(RuntimeObjectKind.objc(.category(.protocol)).isObjC == true)
        #expect(RuntimeObjectKind.c(.struct).isObjC == false)
        #expect(RuntimeObjectKind.swift(.type(.enum)).isObjC == false)
    }

    @Test("isSwift returns true only for Swift kinds")
    func isSwiftProperty() {
        #expect(RuntimeObjectKind.swift(.type(.class)).isSwift == true)
        #expect(RuntimeObjectKind.swift(.extension(.struct)).isSwift == true)
        #expect(RuntimeObjectKind.swift(.conformance(.protocol)).isSwift == true)
        #expect(RuntimeObjectKind.c(.struct).isSwift == false)
        #expect(RuntimeObjectKind.objc(.type(.class)).isSwift == false)
    }

    // MARK: - description

    @Test("C descriptions", arguments: [
        (RuntimeObjectKind.c(.struct), "C Struct"),
        (.c(.union), "C Union"),
    ] as [(RuntimeObjectKind, String)])
    func cDescription(kind: RuntimeObjectKind, expected: String) {
        #expect(kind.description == expected)
    }

    @Test("ObjC descriptions", arguments: [
        (RuntimeObjectKind.objc(.type(.class)), "Objective-C Class"),
        (.objc(.type(.protocol)), "Objective-C Protocol"),
        (.objc(.category(.class)), "Objective-C Class Category"),
        (.objc(.category(.protocol)), "Objective-C Protocol Category"),
    ] as [(RuntimeObjectKind, String)])
    func objcDescription(kind: RuntimeObjectKind, expected: String) {
        #expect(kind.description == expected)
    }

    @Test("Swift descriptions", arguments: [
        (RuntimeObjectKind.swift(.type(.enum)), "Swift Enum"),
        (.swift(.type(.struct)), "Swift Struct"),
        (.swift(.type(.class)), "Swift Class"),
        (.swift(.type(.protocol)), "Swift Protocol"),
        (.swift(.type(.typeAlias)), "Swift TypeAlias"),
        (.swift(.extension(.enum)), "Swift Enum Extension"),
        (.swift(.extension(.struct)), "Swift Struct Extension"),
        (.swift(.extension(.class)), "Swift Class Extension"),
        (.swift(.extension(.protocol)), "Swift Protocol Extension"),
        (.swift(.extension(.typeAlias)), "Swift TypeAlias Extension"),
        (.swift(.conformance(.enum)), "Swift Enum Conformance"),
        (.swift(.conformance(.struct)), "Swift Struct Conformance"),
        (.swift(.conformance(.class)), "Swift Class Conformance"),
        (.swift(.conformance(.protocol)), "Swift Protocol Conformance"),
        (.swift(.conformance(.typeAlias)), "Swift TypeAlias Conformance"),
    ] as [(RuntimeObjectKind, String)])
    func swiftDescription(kind: RuntimeObjectKind, expected: String) {
        #expect(kind.description == expected)
    }

    // MARK: - Comparable

    @Test("C kinds come before ObjC kinds")
    func cBeforeObjC() {
        #expect(RuntimeObjectKind.c(.struct) < .objc(.type(.class)))
        #expect(RuntimeObjectKind.c(.union) < .objc(.type(.class)))
    }

    @Test("ObjC kinds come before Swift kinds")
    func objcBeforeSwift() {
        #expect(RuntimeObjectKind.objc(.category(.protocol)) < .swift(.type(.enum)))
    }

    @Test("Swift types come before Swift extensions")
    func swiftTypeBeforeExtension() {
        #expect(RuntimeObjectKind.swift(.type(.typeAlias)) < .swift(.extension(.enum)))
    }

    @Test("Swift extensions come before Swift conformances")
    func swiftExtensionBeforeConformance() {
        #expect(RuntimeObjectKind.swift(.extension(.typeAlias)) < .swift(.conformance(.enum)))
    }

    // MARK: - CaseIterable

    @Test("allCases contains all 21 cases")
    func allCasesCount() {
        // 2 C + 4 ObjC + 15 Swift = 21
        #expect(RuntimeObjectKind.allCases.count == 21)
    }

    @Test("allCases are in order")
    func allCasesOrdered() {
        let cases = RuntimeObjectKind.allCases
        for i in 0..<cases.count - 1 {
            #expect(cases[i] < cases[i + 1])
        }
    }

    // MARK: - Codable

    @Test("encodes and decodes all cases", arguments: RuntimeObjectKind.allCases)
    func codableRoundTrip(kind: RuntimeObjectKind) throws {
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(RuntimeObjectKind.self, from: data)
        #expect(decoded == kind)
    }

    // MARK: - Identifiable

    @Test("id is self")
    func identifiable() {
        let kind = RuntimeObjectKind.swift(.type(.class))
        #expect(kind.id == kind)
    }
}
