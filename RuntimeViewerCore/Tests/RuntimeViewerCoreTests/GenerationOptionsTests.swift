import Testing
import Foundation
import RuntimeViewerCore

@Suite("ObjCGenerationOptions")
struct ObjCGenerationOptionsTests {
    @Test("default options have all strips disabled and all adds disabled")
    func defaultOptions() {
        let options = ObjCGenerationOptions.default
        #expect(options.stripProtocolConformance == false)
        #expect(options.stripOverrides == false)
        #expect(options.stripSynthesizedIvars == false)
        #expect(options.stripSynthesizedMethods == false)
        #expect(options.stripCtorMethod == false)
        #expect(options.stripDtorMethod == false)
        #expect(options.addIvarOffsetComments == false)
        #expect(options.addPropertyAttributesComments == false)
        #expect(options.addMethodIMPAddressComments == false)
        #expect(options.addPropertyAccessorAddressComments == false)
    }

    @Test("custom initialization sets all fields")
    func customInit() {
        let options = ObjCGenerationOptions(
            stripProtocolConformance: true,
            stripOverrides: true,
            stripSynthesizedIvars: true,
            stripSynthesizedMethods: true,
            stripCtorMethod: true,
            stripDtorMethod: true,
            addIvarOffsetComments: true,
            addPropertyAttributesComments: true,
            addMethodIMPAddressComments: true,
            addPropertyAccessorAddressComments: true
        )
        #expect(options.stripProtocolConformance == true)
        #expect(options.stripOverrides == true)
        #expect(options.addIvarOffsetComments == true)
        #expect(options.addMethodIMPAddressComments == true)
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = ObjCGenerationOptions.default
        let b = ObjCGenerationOptions.default
        #expect(a == b)

        let c = ObjCGenerationOptions(stripProtocolConformance: true)
        #expect(a != c)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = ObjCGenerationOptions(
            stripProtocolConformance: true,
            stripOverrides: false,
            addIvarOffsetComments: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObjCGenerationOptions.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("SwiftGenerationOptions")
struct SwiftGenerationOptionsTests {
    @Test("default options")
    func defaultOptions() {
        let options = SwiftGenerationOptions.default
        #expect(options.printStrippedSymbolicItem == true)
        #expect(options.emitOffsetComments == false)
        #expect(options.printMemberAddress == false)
        #expect(options.printVTableOffset == false)
        #expect(options.printTypeLayout == false)
        #expect(options.printEnumLayout == false)
        #expect(options.synthesizeOpaqueType == false)
    }

    @Test("custom initialization")
    func customInit() {
        let options = SwiftGenerationOptions(
            printStrippedSymbolicItem: false,
            emitOffsetComments: true,
            printMemberAddress: true,
            printVTableOffset: true,
            printTypeLayout: true,
            printEnumLayout: true,
            synthesizeOpaqueType: true
        )
        #expect(options.printStrippedSymbolicItem == false)
        #expect(options.emitOffsetComments == true)
        #expect(options.printMemberAddress == true)
        #expect(options.printVTableOffset == true)
        #expect(options.printTypeLayout == true)
        #expect(options.printEnumLayout == true)
        #expect(options.synthesizeOpaqueType == true)
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = SwiftGenerationOptions.default
        let b = SwiftGenerationOptions.default
        #expect(a == b)

        let c = SwiftGenerationOptions(emitOffsetComments: true)
        #expect(a != c)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = SwiftGenerationOptions(
            printStrippedSymbolicItem: false,
            emitOffsetComments: true,
            printMemberAddress: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SwiftGenerationOptions.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("RuntimeObjectInterface.GenerationOptions")
struct GenerationOptionsTests {
    @Test("mcp preset has maximum information enabled")
    func mcpPreset() {
        let mcp = RuntimeObjectInterface.GenerationOptions.mcp

        // All strip options disabled
        #expect(mcp.objcHeaderOptions.stripProtocolConformance == false)
        #expect(mcp.objcHeaderOptions.stripOverrides == false)
        #expect(mcp.objcHeaderOptions.stripSynthesizedIvars == false)
        #expect(mcp.objcHeaderOptions.stripSynthesizedMethods == false)
        #expect(mcp.objcHeaderOptions.stripCtorMethod == false)
        #expect(mcp.objcHeaderOptions.stripDtorMethod == false)

        // All add options enabled
        #expect(mcp.objcHeaderOptions.addIvarOffsetComments == true)
        #expect(mcp.objcHeaderOptions.addPropertyAttributesComments == true)
        #expect(mcp.objcHeaderOptions.addMethodIMPAddressComments == true)
        #expect(mcp.objcHeaderOptions.addPropertyAccessorAddressComments == true)

        // All Swift detail options enabled
        #expect(mcp.swiftInterfaceOptions.printStrippedSymbolicItem == true)
        #expect(mcp.swiftInterfaceOptions.emitOffsetComments == true)
        #expect(mcp.swiftInterfaceOptions.printMemberAddress == true)
        #expect(mcp.swiftInterfaceOptions.printVTableOffset == true)
        #expect(mcp.swiftInterfaceOptions.printTypeLayout == true)
        #expect(mcp.swiftInterfaceOptions.printEnumLayout == true)
        #expect(mcp.swiftInterfaceOptions.synthesizeOpaqueType == true)
    }

    @Test("default initialization uses default sub-options")
    func defaultInit() {
        let options = RuntimeObjectInterface.GenerationOptions()
        #expect(options.objcHeaderOptions == .default)
        #expect(options.swiftInterfaceOptions == .default)
        #expect(options.transformer == .default)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = RuntimeObjectInterface.GenerationOptions.mcp
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: data)
        #expect(decoded.objcHeaderOptions == original.objcHeaderOptions)
        #expect(decoded.swiftInterfaceOptions == original.swiftInterfaceOptions)
    }
}
