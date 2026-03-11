import Testing
import RuntimeViewerCore
@testable import RuntimeViewerMCPBridge

@Suite("MCPRuntimeTypeInfo")
struct MCPRuntimeTypeInfoTests {
    @Test("init from RuntimeObject maps all fields correctly")
    func initFromRuntimeObject() {
        let object = RuntimeObject(
            name: "_TtC6AppKit6NSView",
            displayName: "NSView",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            children: []
        )
        let info = MCPRuntimeTypeInfo(from: object)

        #expect(info.name == object.name)
        #expect(info.displayName == object.displayName)
        #expect(info.kind == object.kind.description)
        #expect(info.imagePath == object.imagePath)
        #expect(info.imageName == object.imageName)
    }

    @Test("init from RuntimeObject preserves imageName derivation")
    func imageNameDerivation() {
        let object = RuntimeObject(
            name: "NSObject",
            displayName: "NSObject",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/usr/lib/libobjc.A.dylib",
            children: []
        )
        let info = MCPRuntimeTypeInfo(from: object)
        // imageName should be the last path component without extension
        #expect(info.imageName == "libobjc.A")
    }

    @Test("kind description for various RuntimeObjectKinds", arguments: [
        (RuntimeObjectKind.objc(.type(.class)), "Objective-C Class"),
        (.objc(.type(.protocol)), "Objective-C Protocol"),
        (.objc(.category(.class)), "Objective-C Class Category"),
        (.swift(.type(.class)), "Swift Class"),
        (.swift(.type(.struct)), "Swift Struct"),
        (.swift(.type(.enum)), "Swift Enum"),
        (.swift(.type(.protocol)), "Swift Protocol"),
        (.swift(.extension(.class)), "Swift Class Extension"),
        (.c(.struct), "C Struct"),
        (.c(.union), "C Union"),
    ] as [(RuntimeObjectKind, String)])
    func kindDescriptionMapping(kind: RuntimeObjectKind, expectedDescription: String) {
        let object = RuntimeObject(
            name: "TestType",
            displayName: "TestType",
            kind: kind,
            secondaryKind: nil,
            imagePath: "/test/path",
            children: []
        )
        let info = MCPRuntimeTypeInfo(from: object)
        #expect(info.kind == expectedDescription)
    }

    @Test("direct initializer sets all fields")
    func directInit() {
        let info = MCPRuntimeTypeInfo(
            name: "MyClass",
            displayName: "MyClass",
            kind: "Swift Class",
            imagePath: "/path/to/image",
            imageName: "image"
        )
        #expect(info.name == "MyClass")
        #expect(info.displayName == "MyClass")
        #expect(info.kind == "Swift Class")
        #expect(info.imagePath == "/path/to/image")
        #expect(info.imageName == "image")
    }
}

@Suite("MCPMemberAddressInfo")
struct MCPMemberAddressInfoTests {
    @Test("init from RuntimeMemberAddress maps all fields")
    func initFromRuntimeMemberAddress() {
        let member = RuntimeMemberAddress(
            name: "viewDidLoad()",
            kind: "method",
            symbolName: "$s6UIKit14UIViewControllerC11viewDidLoadyyF",
            address: "0x00007FF8123ABC"
        )
        let info = MCPMemberAddressInfo(from: member)

        #expect(info.name == member.name)
        #expect(info.kind == member.kind)
        #expect(info.symbolName == member.symbolName)
        #expect(info.address == member.address)
    }

    @Test("direct initializer sets all fields")
    func directInit() {
        let info = MCPMemberAddressInfo(
            name: "init()",
            kind: "initializer",
            symbolName: "$s4Main7MyClassCACycfc",
            address: "0x100001234"
        )
        #expect(info.name == "init()")
        #expect(info.kind == "initializer")
        #expect(info.symbolName == "$s4Main7MyClassCACycfc")
        #expect(info.address == "0x100001234")
    }
}

@Suite("MCPWindowInfo")
struct MCPWindowInfoTests {
    @Test("initializer sets all fields including nil optionals")
    func initWithNils() {
        let info = MCPWindowInfo(
            identifier: "win-1",
            displayName: nil,
            isKeyWindow: false,
            selectedTypeName: nil,
            selectedTypeImagePath: nil,
            selectedTypeImageName: nil
        )
        #expect(info.identifier == "win-1")
        #expect(info.displayName == nil)
        #expect(info.isKeyWindow == false)
        #expect(info.selectedTypeName == nil)
    }

    @Test("initializer sets all non-nil fields")
    func initWithValues() {
        let info = MCPWindowInfo(
            identifier: "win-2",
            displayName: "My Document",
            isKeyWindow: true,
            selectedTypeName: "NSObject",
            selectedTypeImagePath: "/usr/lib/libobjc.A.dylib",
            selectedTypeImageName: "libobjc.A"
        )
        #expect(info.identifier == "win-2")
        #expect(info.displayName == "My Document")
        #expect(info.isKeyWindow == true)
        #expect(info.selectedTypeName == "NSObject")
        #expect(info.selectedTypeImagePath == "/usr/lib/libobjc.A.dylib")
        #expect(info.selectedTypeImageName == "libobjc.A")
    }
}

@Suite("MCPListWindowsResponse")
struct MCPListWindowsResponseTests {
    @Test("empty windows list")
    func emptyWindows() {
        let response = MCPListWindowsResponse(windows: [])
        #expect(response.windows.isEmpty)
    }

    @Test("multiple windows")
    func multipleWindows() {
        let windows = [
            MCPWindowInfo(identifier: "a", displayName: "Doc A", isKeyWindow: true, selectedTypeName: nil, selectedTypeImagePath: nil, selectedTypeImageName: nil),
            MCPWindowInfo(identifier: "b", displayName: "Doc B", isKeyWindow: false, selectedTypeName: nil, selectedTypeImagePath: nil, selectedTypeImageName: nil),
        ]
        let response = MCPListWindowsResponse(windows: windows)
        #expect(response.windows.count == 2)
        #expect(response.windows[0].identifier == "a")
        #expect(response.windows[1].identifier == "b")
    }
}

@Suite("Request/Response types")
struct RequestResponseTests {
    @Test("MCPSelectedTypeResponse stores all fields")
    func selectedTypeResponse() {
        let response = MCPSelectedTypeResponse(
            imagePath: "/path",
            imageName: "Framework",
            typeName: "MyClass",
            displayName: "MyClass",
            typeKind: "Swift Class",
            interfaceText: "class MyClass {}"
        )
        #expect(response.imagePath == "/path")
        #expect(response.imageName == "Framework")
        #expect(response.typeName == "MyClass")
        #expect(response.displayName == "MyClass")
        #expect(response.typeKind == "Swift Class")
        #expect(response.interfaceText == "class MyClass {}")
    }

    @Test("MCPTypeInterfaceResponse stores error field")
    func typeInterfaceResponseWithError() {
        let response = MCPTypeInterfaceResponse(
            imagePath: nil,
            imageName: nil,
            typeName: nil,
            displayName: nil,
            typeKind: nil,
            interfaceText: nil,
            error: "something failed"
        )
        #expect(response.error == "something failed")
        #expect(response.typeName == nil)
    }

    @Test("MCPLoadImageResponse fields")
    func loadImageResponse() {
        let response = MCPLoadImageResponse(
            imagePath: "/usr/lib/libobjc.A.dylib",
            alreadyLoaded: true,
            objectsLoaded: false,
            error: nil
        )
        #expect(response.imagePath == "/usr/lib/libobjc.A.dylib")
        #expect(response.alreadyLoaded == true)
        #expect(response.objectsLoaded == false)
        #expect(response.error == nil)
    }

    @Test("MCPLoadObjectsResponse fields")
    func loadObjectsResponse() {
        let response = MCPLoadObjectsResponse(
            imagePath: "/path",
            alreadyLoaded: false,
            objectCount: 42,
            error: nil
        )
        #expect(response.objectCount == 42)
        #expect(response.alreadyLoaded == false)
    }

    @Test("MCPIsImageLoadedResponse fields")
    func isImageLoadedResponse() {
        let response = MCPIsImageLoadedResponse(imagePath: "/path", isLoaded: true)
        #expect(response.isLoaded == true)
        #expect(response.imagePath == "/path")
    }

    @Test("MCPIsObjectsLoadedResponse fields")
    func isObjectsLoadedResponse() {
        let response = MCPIsObjectsLoadedResponse(imagePath: "/path", isLoaded: false)
        #expect(response.isLoaded == false)
    }

    @Test("MCPListTypesResponse with types")
    func listTypesResponse() {
        let types = [
            MCPRuntimeTypeInfo(name: "A", displayName: "A", kind: "Swift Class", imagePath: "/p", imageName: "img"),
        ]
        let response = MCPListTypesResponse(types: types, error: nil)
        #expect(response.types.count == 1)
        #expect(response.error == nil)
    }

    @Test("MCPSearchTypesResponse with error")
    func searchTypesResponseWithError() {
        let response = MCPSearchTypesResponse(types: [], error: "not found")
        #expect(response.types.isEmpty)
        #expect(response.error == "not found")
    }

    @Test("MCPSearchImagesResponse stores paths")
    func searchImagesResponse() {
        let response = MCPSearchImagesResponse(imagePaths: ["/a", "/b"])
        #expect(response.imagePaths.count == 2)
    }

    @Test("MCPMemberAddressesResponse fields")
    func memberAddressesResponse() {
        let members = [
            MCPMemberAddressInfo(name: "foo", kind: "method", symbolName: "_foo", address: "0x1"),
        ]
        let response = MCPMemberAddressesResponse(typeName: "Bar", members: members, error: nil)
        #expect(response.typeName == "Bar")
        #expect(response.members.count == 1)
        #expect(response.error == nil)
    }

    @Test("MCPGrepMatch stores matching lines")
    func grepMatch() {
        let match = MCPGrepMatch(typeName: "NSView", kind: "Objective-C Class", matchingLines: ["line1", "line2"])
        #expect(match.typeName == "NSView")
        #expect(match.matchingLines.count == 2)
    }
}
