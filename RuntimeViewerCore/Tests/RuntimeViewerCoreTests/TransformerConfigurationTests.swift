import Foundation
import Testing
import OutputTransformer
import ObjCOutputTransformer
import SwiftOutputTransformer
import RuntimeViewerCore

/// The concrete transformer modules live with their subject matter — the ObjC
/// ones in MachOObjCSection, the Swift ones in MachOSwiftSection — and are
/// tested there. What is exercised here is the aggregate that only
/// RuntimeViewer needs: it spans both halves and is what gets persisted.
@Suite("Transformer.Configuration")
struct TransformerConfigurationTests {
    @Test("Both halves are reachable through one namespace")
    func bothHalvesShareOneNamespace() {
        // The modules come from two different packages but extend the same
        // `Transformer` namespace, so neither needs qualifying.
        #expect(Transformer.CType.displayName == "C Type Replacement")
        #expect(Transformer.SwiftEnumLayout.displayName == "Enum Layout Comment")
    }

    @Test("Persistence round-trips and tolerates missing keys")
    func persistenceRoundTrips() throws {
        var configuration = Transformer.Configuration()
        configuration.swift.swiftFieldOffset.isEnabled = true
        configuration.swift.swiftEnumLayout = .explained
        configuration.objc.cType = .init(isEnabled: true, replacements: Transformer.CType.Presets.foundation)

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(Transformer.Configuration.self, from: encoded)
        #expect(decoded == configuration)

        // Settings stored by older versions may lack any key.
        let emptyDecoded = try JSONDecoder().decode(Transformer.Configuration.self, from: Data("{}".utf8))
        #expect(emptyDecoded == .default)
    }

    @Test("hasEnabledModules covers both sides")
    func hasEnabledModulesCoversBothSides() {
        var configuration = Transformer.Configuration.default
        #expect(!configuration.hasEnabledModules)
        configuration.objc.ivarOffset.isEnabled = true
        #expect(configuration.hasEnabledModules)
        configuration = .default
        configuration.swift.swiftTypeLayout.isEnabled = true
        #expect(configuration.hasEnabledModules)
    }
}
