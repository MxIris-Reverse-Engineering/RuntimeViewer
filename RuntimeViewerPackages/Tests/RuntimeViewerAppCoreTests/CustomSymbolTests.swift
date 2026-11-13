import AppKit
import Testing
@testable import RuntimeViewerAppCore

/// The symbols RuntimeViewerAppCore ships in its own asset catalog (proposal `draft-image-kind-icons`).
/// They are named by string, so a misspelt name or a symbol set left out of the catalog is caught here.
@Suite("Custom symbols")
struct CustomSymbolTests {
    @Test("the asset catalog has every symbol, and each is a symbol image", arguments: CustomSymbol.allCases)
    func assetCatalogHasSymbol(symbol: CustomSymbol) throws {
        let image = try #require(
            CustomSymbol.imageInAssetCatalog(named: symbol.rawValue),
            "the asset catalog has no symbol named \(symbol.rawValue)"
        )

        #expect(image.isTemplate)
        let largerImage = try #require(image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .light)))
        #expect(largerImage.size.height > image.size.height, "a symbol image grows with its point size")
    }

    @Test("asking for a symbol the asset catalog does not have stops the process")
    func missingSymbolStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            _ = CustomSymbol.image(named: "runtimeviewer.no.such.symbol")
        }
    }

    @Test("every symbol set is a version 6 template, the version macOS 15 reads", arguments: CustomSymbol.allCases)
    func templateVersion(symbol: CustomSymbol) throws {
        let assetCatalogURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../Sources/RuntimeViewerAppCore/Resources/Symbols.xcassets")
            .standardized
        let symbolSetURL = assetCatalogURL.appending(path: "\(symbol.rawValue).symbolset")
        let templateURLs = try FileManager.default.contentsOfDirectory(at: symbolSetURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svg" }
        let templateURL = try #require(templateURLs.first, "no template in \(symbolSetURL.path)")

        let template = try String(contentsOf: templateURL, encoding: .utf8)

        #expect(template.contains(">Template v.6.0<"))
    }
}
