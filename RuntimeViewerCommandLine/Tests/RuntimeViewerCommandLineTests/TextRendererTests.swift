import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// Snapshots of the text rendering, so a column or wording change is a
/// deliberate edit here rather than a surprise on the terminal.
@Suite("Text rendering")
struct TextRendererTests {
    private static let nsObject = TypeInfo(name: "NSObject", displayName: "NSObject", kind: "Objective-C Class", imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A")
    private static let array = TypeInfo(name: "$sSaMa", displayName: "Array<Element>", kind: "Swift Struct", imagePath: "/usr/lib/swift/libswiftCore.dylib", imageName: "libswiftCore")

    @Test("Image list is a LOADED / NAME / PATH table")
    func imageList() {
        let rendered = TextRenderer.render(.imageList(ImageListResult(images: [
            ImageInfo(path: "/usr/lib/libobjc.A.dylib", name: "libobjc.A", isLoaded: true),
            ImageInfo(path: "/System/Library/Frameworks/Foundation.framework/Foundation", name: "Foundation", isLoaded: false),
        ])))
        #expect(rendered.output == """
            LOADED  NAME        PATH
            *       libobjc.A   /usr/lib/libobjc.A.dylib
                    Foundation  /System/Library/Frameworks/Foundation.framework/Foundation

            """)
        #expect(rendered.notes.isEmpty)
    }

    @Test("Type list is a KIND / NAME / IMAGE table")
    func typeList() {
        let rendered = TextRenderer.render(.typeList(TypeListResult(imagePaths: ["/usr/lib/libobjc.A.dylib"], types: [Self.nsObject, Self.array])))
        #expect(rendered.output == """
            KIND               NAME            IMAGE
            Objective-C Class  NSObject        libobjc.A
            Swift Struct       Array<Element>  libswiftCore

            """)
    }

    @Test("An empty type list says where it looked")
    func emptyTypeList() {
        let rendered = TextRenderer.render(.typeList(TypeListResult(imagePaths: ["/usr/lib/libobjc.A.dylib"], types: [])))
        #expect(rendered.output == "No types matched in /usr/lib/libobjc.A.dylib.\n")
    }

    @Test("Member addresses are an ADDRESS / KIND / NAME / SYMBOL table")
    func memberAddresses() {
        let rendered = TextRenderer.render(.memberAddresses(MemberAddressesResult(typeInfo: Self.nsObject, members: [
            MemberAddress(name: "description", kind: "Instance Method", symbolName: "-[NSObject description]", address: "0x18001a2b4"),
            MemberAddress(name: "init", kind: "Instance Method", symbolName: "-[NSObject init]", address: "0x18001a000"),
        ])))
        #expect(rendered.output == """
            ADDRESS      KIND             NAME         SYMBOL
            0x18001a2b4  Instance Method  description  -[NSObject description]
            0x18001a000  Instance Method  init         -[NSObject init]

            """)
    }

    @Test("Interfaces print verbatim with a final newline")
    func interface() {
        let rendered = TextRenderer.render(.interface(InterfaceResult(typeInfo: Self.nsObject, interfaceText: "@interface NSObject\n@end")))
        #expect(rendered.output == "@interface NSObject\n@end\n")
    }

    @Test("Specialization warnings go to the notes, not into the interface")
    func specializedWarnings() {
        let rendered = TextRenderer.render(.specialized(SpecializedInterfaceResult(typeInfo: Self.array, interfaceText: "struct Array<Int> {}\n", warnings: ["layout differs"])))
        #expect(rendered.output == "struct Array<Int> {}\n")
        #expect(rendered.notes == ["warning: layout differs"])
    }

    @Test("Hierarchy indents one level per ancestor")
    func hierarchy() {
        let rendered = TextRenderer.render(.hierarchy(HierarchyResult(typeInfo: Self.nsObject, hierarchy: ["NSObject", "NSResponder", "NSView"])))
        #expect(rendered.output == "NSObject\n  NSResponder\n    NSView\n")
    }

    @Test("Relationships list both groups with counts")
    func relationships() {
        let rendered = TextRenderer.render(.relationships(RelationshipsResult(typeInfo: Self.nsObject, subclasses: [Self.array], conformingTypes: [])))
        #expect(rendered.output == """
            Subclasses (1):
              Array<Element> (libswiftCore)
            Conforming types (0):

            """)
    }

    @Test("Specialization parameters list their candidates")
    func specializationParameters() {
        let rendered = TextRenderer.render(.specializationParameters(SpecializationParametersResult(typeInfo: Self.array, parameters: [
            SpecializationParameter(name: "Element", displayDescription: "Element", candidates: [
                SpecializationCandidate(displayName: "Int", imagePath: "/usr/lib/swift/libswiftCore.dylib", imageName: "libswiftCore", kind: "struct", isGeneric: false),
                SpecializationCandidate(displayName: "Optional<Wrapped>", imagePath: "/usr/lib/swift/libswiftCore.dylib", imageName: "libswiftCore", kind: "enum", isGeneric: true),
            ]),
        ])))
        #expect(rendered.output == """
            Generic parameters of Array<Element>:
              Element: Element
                - Int (struct, libswiftCore)
                - Optional<Wrapped> (enum, libswiftCore, generic)

            """)
    }

    @Test("Export summarises counts and duration")
    func export() {
        let rendered = TextRenderer.render(.export(ExportResult(imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A", outputDirectory: "/tmp/out", succeeded: 12, failed: 1, objcCount: 12, swiftCount: 0, totalDuration: 2.345)))
        #expect(rendered.output == "Exported 12 interfaces of libobjc.A to /tmp/out in 2.3 s (Objective-C 12, Swift 0, 1 failed).\n")
    }

    @Test("Failures render as one error line with the code")
    func failure() {
        #expect(TextRenderer.render(CommandFailure(code: .imageNotFound, message: "No image matches 'Foo'.")) == "error: No image matches 'Foo'. [imageNotFound]\n")
    }

    @Test("Host status is a key/value block")
    func hostStatus() {
        let rendered = TextRenderer.render(.hostStatus(HostStatusResult(processIdentifier: 4242, kind: .standalone, version: "0.1.0", protocolVersion: 1, startedAt: Date(timeIntervalSince1970: 1_700_000_000), activeConnections: 1, inFlightCommands: 0, idleTimeout: 600, isShuttingDown: false, loadedImagePaths: ["/usr/lib/libobjc.A.dylib"])))
        #expect(rendered.output == """
            Kind:               standalone
            Process:            4242
            Version:            0.1.0 (protocol 1)
            Started:            2023-11-14T22:13:20Z
            Connections:        1
            Commands in flight: 0
            Idle timeout:       600 s
            Shutting down:      no
            Loaded images:      1
              /usr/lib/libobjc.A.dylib

            """)
    }
}
