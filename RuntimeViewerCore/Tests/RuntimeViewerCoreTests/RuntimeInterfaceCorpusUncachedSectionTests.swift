import Foundation
import SwiftDeclaration
@_spi(Support) import SwiftIndexing
import Testing
@testable import RuntimeViewerCore

/// A corpus build prints every Swift definition of its image, and printing a
/// definition resolves its members and their symbols, which the definition
/// keeps for as long as it lives. Printed on the cached section — the one the
/// content pane prints from — they stayed for the life of the engine's
/// process: a launch that printed its corpora held about 70 MB more than one
/// that read them back from derived data (proposal
/// `throwaway-corpus-swift-section`). The build prints on a section made for
/// it, so the cached section's definitions stay as unresolved as the build
/// found them.
@Suite("RuntimeInterfaceCorpus prints on an uncached Swift section")
struct RuntimeInterfaceCorpusUncachedSectionTests {
    /// Indexes in well under a second, and has types, protocols and
    /// extensions to print.
    private static let observationPath = "/usr/lib/swift/libswiftObservation.dylib"

    @Test("building a corpus leaves the cached Swift section's definitions unresolved")
    func buildingLeavesCachedDefinitionsUnresolved() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-corpus-uncached-swift-section")
        try await engine.connect()
        try await engine.loadImage(at: Self.observationPath)
        let firstSwiftObject = try await engine.objects(in: Self.observationPath).first(where: \.kind.isSwift)
        let swiftObject = try #require(firstSwiftObject)
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: swiftObject.imagePath) as? RuntimeSwiftSection<RuntimeLoadedImageReading>)
        let resolvedCountBeforeBuild = Self.resolvedDefinitionCount(in: section)

        let summary = try await engine.buildInterfaceCorpus(for: Self.observationPath, transformer: .default)

        try #require(summary.objectCount > 0)
        #expect(Self.resolvedDefinitionCount(in: section) == resolvedCountBeforeBuild)
    }

    /// How many of the section's type, protocol and extension definitions
    /// have resolved their members.
    private static func resolvedDefinitionCount(in section: RuntimeSwiftSection<RuntimeLoadedImageReading>) -> Int {
        let indexer = section.indexer
        let resolvedTypeCount = indexer.allTypeDefinitions.values.filter(\.isIndexed).count
        let resolvedProtocolCount = indexer.allProtocolDefinitions.values.filter(\.isIndexed).count
        let resolvedExtensionCount = [
            indexer.typeExtensionDefinitions.values.flatMap { $0 },
            indexer.protocolExtensionDefinitions.values.flatMap { $0 },
            indexer.typeAliasExtensionDefinitions.values.flatMap { $0 },
            indexer.conformanceExtensionDefinitions.values.flatMap { $0 },
        ].joined().filter(\.isIndexed).count
        return resolvedTypeCount + resolvedProtocolCount + resolvedExtensionCount
    }
}
