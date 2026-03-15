import Testing
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerMCPBridge

@Suite("MCPProtocol Codable round-trips")
struct MCPBridgeProtocolCodableTests {
    // MARK: - MCPRuntimeTypeInfo

    @Test("MCPRuntimeTypeInfo Codable round-trip")
    func runtimeTypeInfoCodable() throws {
        let original = MCPRuntimeTypeInfo(
            name: "_TtC6AppKit6NSView",
            displayName: "NSView",
            kind: "Objective-C Class",
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            imageName: "AppKit"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPRuntimeTypeInfo.self, from: data)
        #expect(decoded.name == original.name)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.kind == original.kind)
        #expect(decoded.imagePath == original.imagePath)
        #expect(decoded.imageName == original.imageName)
    }

    // MARK: - MCPMemberAddressInfo

    @Test("MCPMemberAddressInfo Codable round-trip")
    func memberAddressInfoCodable() throws {
        let original = MCPMemberAddressInfo(
            name: "viewDidLoad()",
            kind: "func",
            symbolName: "$s6UIKit14UIViewControllerC11viewDidLoadyyF",
            address: "0x00007FF8123ABC"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPMemberAddressInfo.self, from: data)
        #expect(decoded.name == original.name)
        #expect(decoded.kind == original.kind)
        #expect(decoded.symbolName == original.symbolName)
        #expect(decoded.address == original.address)
    }

    // MARK: - MCPWindowInfo

    @Test("MCPWindowInfo Codable round-trip with nil fields")
    func windowInfoCodableNils() throws {
        let original = MCPWindowInfo(
            identifier: "win-1",
            displayName: nil,
            isKeyWindow: false,
            selectedTypeName: nil,
            selectedTypeImagePath: nil,
            selectedTypeImageName: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPWindowInfo.self, from: data)
        #expect(decoded.identifier == original.identifier)
        #expect(decoded.displayName == nil)
        #expect(decoded.isKeyWindow == false)
        #expect(decoded.selectedTypeName == nil)
    }

    @Test("MCPWindowInfo Codable round-trip with all fields")
    func windowInfoCodableAll() throws {
        let original = MCPWindowInfo(
            identifier: "win-2",
            displayName: "Document",
            isKeyWindow: true,
            selectedTypeName: "NSObject",
            selectedTypeImagePath: "/usr/lib/libobjc.A.dylib",
            selectedTypeImageName: "libobjc.A"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPWindowInfo.self, from: data)
        #expect(decoded.identifier == original.identifier)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.isKeyWindow == original.isKeyWindow)
        #expect(decoded.selectedTypeName == original.selectedTypeName)
        #expect(decoded.selectedTypeImagePath == original.selectedTypeImagePath)
        #expect(decoded.selectedTypeImageName == original.selectedTypeImageName)
    }

    // MARK: - MCPListWindowsResponse

    @Test("MCPListWindowsResponse Codable round-trip")
    func listWindowsResponseCodable() throws {
        let original = MCPListWindowsResponse(windows: [
            MCPWindowInfo(identifier: "a", displayName: "Doc A", isKeyWindow: true, selectedTypeName: nil, selectedTypeImagePath: nil, selectedTypeImageName: nil),
            MCPWindowInfo(identifier: "b", displayName: nil, isKeyWindow: false, selectedTypeName: "NSView", selectedTypeImagePath: "/path", selectedTypeImageName: "img"),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPListWindowsResponse.self, from: data)
        #expect(decoded.windows.count == 2)
        #expect(decoded.windows[0].identifier == "a")
        #expect(decoded.windows[1].selectedTypeName == "NSView")
    }

    // MARK: - MCPSelectedTypeResponse

    @Test("MCPSelectedTypeResponse Codable round-trip")
    func selectedTypeResponseCodable() throws {
        let original = MCPSelectedTypeResponse(
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            imageName: "AppKit",
            typeName: "NSView",
            displayName: "NSView",
            typeKind: "Objective-C Class",
            interfaceText: "@interface NSView : NSResponder\n@end"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPSelectedTypeResponse.self, from: data)
        #expect(decoded.typeName == "NSView")
        #expect(decoded.interfaceText == original.interfaceText)
    }

    // MARK: - MCPTypeInterfaceResponse

    @Test("MCPTypeInterfaceResponse Codable round-trip with error")
    func typeInterfaceResponseCodable() throws {
        let original = MCPTypeInterfaceResponse(
            imagePath: nil,
            imageName: nil,
            typeName: nil,
            displayName: nil,
            typeKind: nil,
            interfaceText: nil,
            error: "Type not found"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPTypeInterfaceResponse.self, from: data)
        #expect(decoded.error == "Type not found")
        #expect(decoded.typeName == nil)
    }

    @Test("MCPTypeInterfaceResponse Codable round-trip with success")
    func typeInterfaceResponseCodableSuccess() throws {
        let original = MCPTypeInterfaceResponse(
            imagePath: "/path",
            imageName: "Framework",
            typeName: "MyClass",
            displayName: "MyClass",
            typeKind: "Swift Class",
            interfaceText: "class MyClass {}",
            error: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPTypeInterfaceResponse.self, from: data)
        #expect(decoded.typeName == "MyClass")
        #expect(decoded.error == nil)
    }

    // MARK: - MCPListTypesResponse

    @Test("MCPListTypesResponse Codable round-trip")
    func listTypesResponseCodable() throws {
        let types = [
            MCPRuntimeTypeInfo(name: "A", displayName: "A", kind: "Swift Class", imagePath: "/p", imageName: "img"),
            MCPRuntimeTypeInfo(name: "B", displayName: "B", kind: "C Struct", imagePath: "/q", imageName: "img2"),
        ]
        let original = MCPListTypesResponse(types: types, error: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPListTypesResponse.self, from: data)
        #expect(decoded.types.count == 2)
        #expect(decoded.types[0].name == "A")
        #expect(decoded.error == nil)
    }

    // MARK: - MCPSearchTypesResponse

    @Test("MCPSearchTypesResponse Codable round-trip")
    func searchTypesResponseCodable() throws {
        let original = MCPSearchTypesResponse(types: [], error: "no results")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPSearchTypesResponse.self, from: data)
        #expect(decoded.types.isEmpty)
        #expect(decoded.error == "no results")
    }

    // MARK: - MCPLoadImageResponse

    @Test("MCPLoadImageResponse Codable round-trip")
    func loadImageResponseCodable() throws {
        let original = MCPLoadImageResponse(imagePath: "/usr/lib/libobjc.A.dylib", alreadyLoaded: false, objectsLoaded: true, error: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPLoadImageResponse.self, from: data)
        #expect(decoded.imagePath == original.imagePath)
        #expect(decoded.alreadyLoaded == false)
        #expect(decoded.objectsLoaded == true)
    }

    // MARK: - MCPLoadObjectsResponse

    @Test("MCPLoadObjectsResponse Codable round-trip")
    func loadObjectsResponseCodable() throws {
        let original = MCPLoadObjectsResponse(imagePath: "/path", alreadyLoaded: true, objectCount: 100, error: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPLoadObjectsResponse.self, from: data)
        #expect(decoded.objectCount == 100)
        #expect(decoded.alreadyLoaded == true)
    }

    // MARK: - MCPIsImageLoadedResponse

    @Test("MCPIsImageLoadedResponse Codable round-trip")
    func isImageLoadedResponseCodable() throws {
        let original = MCPIsImageLoadedResponse(imagePath: "/test/path", isLoaded: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPIsImageLoadedResponse.self, from: data)
        #expect(decoded.imagePath == "/test/path")
        #expect(decoded.isLoaded == true)
    }

    // MARK: - MCPIsObjectsLoadedResponse

    @Test("MCPIsObjectsLoadedResponse Codable round-trip")
    func isObjectsLoadedResponseCodable() throws {
        let original = MCPIsObjectsLoadedResponse(imagePath: "/test/path", isLoaded: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPIsObjectsLoadedResponse.self, from: data)
        #expect(decoded.imagePath == "/test/path")
        #expect(decoded.isLoaded == false)
    }

    // MARK: - MCPListImagesResponse

    @Test("MCPListImagesResponse Codable round-trip")
    func listImagesResponseCodable() throws {
        let original = MCPListImagesResponse(imagePaths: ["/a", "/b", "/c"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPListImagesResponse.self, from: data)
        #expect(decoded.imagePaths == ["/a", "/b", "/c"])
    }

    // MARK: - MCPSearchImagesResponse

    @Test("MCPSearchImagesResponse Codable round-trip")
    func searchImagesResponseCodable() throws {
        let original = MCPSearchImagesResponse(imagePaths: ["/System/AppKit", "/System/Foundation"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPSearchImagesResponse.self, from: data)
        #expect(decoded.imagePaths.count == 2)
    }

    // MARK: - MCPMemberAddressesResponse

    @Test("MCPMemberAddressesResponse Codable round-trip")
    func memberAddressesResponseCodable() throws {
        let original = MCPMemberAddressesResponse(
            typeName: "NSView",
            members: [
                MCPMemberAddressInfo(name: "init", kind: "init", symbolName: "_sym1", address: "0x1"),
                MCPMemberAddressInfo(name: "draw", kind: "func", symbolName: "_sym2", address: "0x2"),
            ],
            error: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPMemberAddressesResponse.self, from: data)
        #expect(decoded.typeName == "NSView")
        #expect(decoded.members.count == 2)
        #expect(decoded.error == nil)
    }

    // MARK: - MCPGrepMatch

    @Test("MCPGrepMatch Codable round-trip")
    func grepMatchCodable() throws {
        let original = MCPGrepMatch(typeName: "NSView", kind: "Objective-C Class", matchingLines: [
            "@property (nonatomic) CGRect frame;",
            "- (void)setNeedsDisplay:(BOOL)flag;",
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPGrepMatch.self, from: data)
        #expect(decoded.typeName == "NSView")
        #expect(decoded.kind == "Objective-C Class")
        #expect(decoded.matchingLines.count == 2)
    }
}
