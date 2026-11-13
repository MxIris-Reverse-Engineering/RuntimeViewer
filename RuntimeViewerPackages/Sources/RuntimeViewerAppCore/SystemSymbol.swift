import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system symbols this module draws. A case's raw value is the symbol's name; `SystemSymbolTests`
/// loads every case, which is what SFSymbols' typed names used to check at compile time.
package enum SystemSymbol: String, CaseIterable, Sendable {
    // Image lists (`RuntimeImageKind`; the bundles' symbols are `CustomSymbol`s)
    case doc
    case folder

    // Find results
    case textAlignleft = "text.alignleft"
    case questionmarkSquare = "questionmark.square"
    case chevronRight = "chevron.right"
    case chevronDown = "chevron.down"
    case arrowTriangle2Circlepath = "arrow.triangle.2.circlepath"
    case hourglass
    case exclamationmarkTriangle = "exclamationmark.triangle"

    // Report
    case squareStack3dDownRight = "square.stack.3d.down.right"
    case magnifyingglass
    case arrowTriangleBranch = "arrow.triangle.branch"
    case trayAndArrowDown = "tray.and.arrow.down"
    case powerCircle = "power.circle"
    case exclamationmarkCircle = "exclamationmark.circle"
    case archivebox

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
