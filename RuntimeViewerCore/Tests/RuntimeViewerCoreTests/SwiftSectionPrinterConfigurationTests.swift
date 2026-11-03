import Foundation
import Testing
@testable import RuntimeViewerCore

/// What `RuntimeSwiftSection.updateConfiguration(using:transformer:marksCommentStructure:)`
/// does to the section's printer. The engine updates the section before every
/// Swift interface it prints, almost always with the options it already has,
/// so an update that changes nothing must leave the printer alone: a new
/// configuration makes an offline printer throw away its static layout
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

    private static func update(_ section: RuntimeSwiftSection<RuntimeLoadedImageReading>, with options: SwiftGenerationOptions) async throws {
        try await section.updateConfiguration(using: options, transformer: .init(), marksCommentStructure: false)
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
