import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The symbols this module ships in its own asset catalog (`Resources/Symbols.xcassets`), taken from
/// Xcode's. A case's raw value is the symbol set's name; `CustomSymbolTests` loads every case.
///
/// The symbol sets are SF Symbols 7 templates downgraded to version 6, the version of the macOS 15 era
/// the app still runs on: version 7 adds only a drawing animation property to them
/// (proposal `draft-image-kind-icons`). Keep a new one at version 6 as well.
package enum CustomSymbol: String, CaseIterable, Sendable {
    /// Xcode's `doc-framework`.
    case framework

    /// Xcode's `doc-bundle.fill`, the symbol Xcode draws a bundle with.
    case bundle = "bundle.fill"

    /// Xcode's `doc-app.fill`, the symbol Xcode draws an app with.
    case application = "app.fill"

    /// Xcode's `doc-kext`.
    case kernelExtension = "kext"

    /// The symbol at the system's default size. Traps when the asset catalog has no symbol of this
    /// name, as `SystemSymbol` does for the system's.
    package var image: NSUIImage {
        Self.image(named: rawValue)
    }

    /// The symbol named `name` in this module's asset catalog; traps when it has none.
    static func image(named name: String) -> NSUIImage {
        guard let image = imageInAssetCatalog(named: name) else {
            fatalError("The asset catalog has no symbol named \(name)")
        }
        return image
    }

    /// The symbol named `name` in this module's asset catalog, or `nil` when it has none.
    static func imageInAssetCatalog(named name: String) -> NSUIImage? {
        #if os(macOS)
        // `variableValue` only matters to a variable symbol, which none of these is.
        return NSImage(symbolName: name, bundle: .module, variableValue: 0)
        #else
        return UIImage(named: name, in: .module, with: nil)
        #endif
    }
}
