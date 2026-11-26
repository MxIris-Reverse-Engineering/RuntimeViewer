import Foundation
import Testing
@testable import RuntimeViewerCore

/// What `RuntimeSwiftSection.updateConfiguration(using:transformer:marksCommentStructure:marksAttachedMacros:)`
/// does to the section's printer. The engine updates the section before every
/// Swift interface it prints, almost always with the options it already has,
/// so an update that changes nothing must leave the printer alone: a new
/// configuration makes a file engine's printer throw away its static layout
/// calculator, which resolves every image the printed image depends on, and
/// the printer keeps every opaque type resolver it is given.
@Suite("Swift section printer configuration", .serialized)
struct SwiftSectionPrinterConfigurationTests {
    private struct SectionNotFound: Error {}

    /// This test bundle's image, whose Swift section the tests update.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    /// One engine for the suite, kept alive with the section it made for this
    /// bundle.
    private static let sharedSection = Task<(engine: RuntimeEngine, section: RuntimeSwiftSection<RuntimeLoadedImageReading>), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "SwiftSectionPrinterConfigurationTests")
        try await engine.connect()
        let objects = try await engine.objects(in: testBundlePath)
        guard let imagePath = objects.first(where: \.kind.isSwift)?.imagePath,
              let section = await engine.swiftSectionFactory.existingSection(for: imagePath) as? RuntimeSwiftSection<RuntimeLoadedImageReading>
        else {
            throw SectionNotFound()
        }
        return (engine, section)
    }

    private static func update(_ section: RuntimeSwiftSection<RuntimeLoadedImageReading>, with options: SwiftGenerationOptions, objcTransformer: Transformer.ObjCConfiguration = .init()) async throws {
        try await section.updateConfiguration(using: options, transformer: .init(), objcTransformer: objcTransformer, marksCommentStructure: false, marksAttachedMacros: false)
    }

    /// The Objective-C side's C Type Replacement setting spelling `double` as `CGFloat`.
    private static let doubleAsCGFloat = Transformer.ObjCConfiguration(cType: .init(isEnabled: true, replacements: [.double: "CGFloat"]))

    /// A recovered Objective-C instance variable type is spelled with the
    /// Objective-C side's C Type Replacement setting (proposal
    /// `objc-ivar-type-recovery` in MachOSwiftSection), so both sides of a
    /// class spell a C primitive alike. A change of the setting reconfigures
    /// the printer like a changed option, and an equal one leaves it alone.
    @Test("enabled C type replacements reach the printer once, and leaving them out takes them back")
    func cTypeReplacementsReachThePrinter() async throws {
        let section = try await Self.sharedSection.value.section
        let options = SwiftGenerationOptions()
        try await Self.update(section, with: options)
        let configurationUpdates = await section.printerConfigurationUpdateCount

        try await Self.update(section, with: options, objcTransformer: Self.doubleAsCGFloat)
        try await Self.update(section, with: options, objcTransformer: Self.doubleAsCGFloat)

        #expect(await section.printerCTypeReplacements == [.double: "CGFloat"])
        #expect(await section.printerConfigurationUpdateCount == configurationUpdates + 1)

        try await Self.update(section, with: options)

        #expect(await section.printerCTypeReplacements.isEmpty)
    }

    @Test("a disabled C type module hands the printer no replacements")
    func disabledCTypeModuleHandsNoReplacements() async throws {
        let section = try await Self.sharedSection.value.section
        var objcTransformer = Self.doubleAsCGFloat
        objcTransformer.cType.isEnabled = false

        try await Self.update(section, with: SwiftGenerationOptions(), objcTransformer: objcTransformer)

        #expect(await section.printerCTypeReplacements.isEmpty)
    }

    /// The corpus is printed with the transformer Find searches with, so a
    /// search for `CGFloat` finds the instance variables the display shows
    /// with it.
    @Test("the corpus printer prints with the C type replacements of the transformer it is given")
    func corpusPrinterTakesTheReplacements() async throws {
        let (engine, section) = try await Self.sharedSection.value
        let object = try #require(try await engine.objects(in: Self.testBundlePath).first(where: \.kind.isSwift))

        _ = try await section.corpusPrints(of: [object], transformer: Transformer.Configuration(objc: Self.doubleAsCGFloat))

        #expect(await section.corpusPrinterCTypeReplacements == [.double: "CGFloat"])

        _ = try await section.corpusPrints(of: [object], transformer: Transformer.Configuration())

        #expect(await section.corpusPrinterCTypeReplacements == [:])
    }

    @Test("updating with the options a section already has leaves its printer alone")
    func sameOptionsLeaveThePrinterAlone() async throws {
        let section = try await Self.sharedSection.value.section
        var options = SwiftGenerationOptions()
        options.printFieldOffset = true
        options.printTypeLayout = true
        options.synthesizeOpaqueType = true
        try await Self.update(section, with: options)
        let configurationUpdates = await section.printerConfigurationUpdateCount
        let resolverRegistrations = await section.opaqueTypeResolverRegistrationCount

        for _ in 0 ..< 3 {
            try await Self.update(section, with: options)
        }

        #expect(await section.printerConfigurationUpdateCount == configurationUpdates)
        #expect(await section.opaqueTypeResolverRegistrationCount == resolverRegistrations)
    }

    /// The spelling is the printer's (proposal `c-imported-type-name-spelling` in MachOSwiftSection),
    /// so changing it hands the printer a new configuration, which drops the printed interfaces.
    @Test("changing the C-imported type name spelling reconfigures the printer once")
    func changedSpellingReconfiguresOnce() async throws {
        let section = try await Self.sharedSection.value.section
        var options = SwiftGenerationOptions()
        try await Self.update(section, with: options)
        let configurationUpdates = await section.printerConfigurationUpdateCount

        options.cImportedTypeNameSpelling = .cName
        try await Self.update(section, with: options)
        try await Self.update(section, with: options)

        #expect(await section.printerConfigurationUpdateCount == configurationUpdates + 1)
    }

    @Test("a changed option reconfigures the printer once, and the opaque type resolver is registered again only after it was turned off")
    func changedOptionsReconfigureOnce() async throws {
        let section = try await Self.sharedSection.value.section
        var options = SwiftGenerationOptions()
        options.synthesizeOpaqueType = true
        try await Self.update(section, with: options)
        let configurationUpdates = await section.printerConfigurationUpdateCount
        let resolverRegistrations = await section.opaqueTypeResolverRegistrationCount

        options.printEnumLayout.toggle()
        try await Self.update(section, with: options)
        try await Self.update(section, with: options)

        #expect(await section.printerConfigurationUpdateCount == configurationUpdates + 1)
        #expect(await section.opaqueTypeResolverRegistrationCount == resolverRegistrations)

        options.synthesizeOpaqueType = false
        try await Self.update(section, with: options)
        options.synthesizeOpaqueType = true
        try await Self.update(section, with: options)
        try await Self.update(section, with: options)

        #expect(await section.opaqueTypeResolverRegistrationCount == resolverRegistrations + 1)
    }
}
