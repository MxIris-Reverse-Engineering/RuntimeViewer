import Foundation
import RuntimeViewerAppCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension SystemSymbol {
    /// The symbol at the system's default size. Traps when the system has no symbol of this name, as
    /// SFSymbols did.
    package var image: NSUIImage {
        Self.image(named: rawValue)
    }

    #if os(macOS)
    /// The symbol at `pointSize` and `weight`. Traps when the system has no symbol of this name, as
    /// SFSymbols did.
    package func image(pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        let image = image
        // Only a symbol image takes a symbol configuration, and `image` always is one.
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) ?? image
    }
    #endif

    /// The system symbol named `name`; traps when the system has none.
    static func image(named name: String) -> NSUIImage {
        #if os(macOS)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        #else
        let image = UIImage(systemName: name)
        #endif
        guard let image else {
            fatalError("The system has no symbol named \(name)")
        }
        return image
    }
}
