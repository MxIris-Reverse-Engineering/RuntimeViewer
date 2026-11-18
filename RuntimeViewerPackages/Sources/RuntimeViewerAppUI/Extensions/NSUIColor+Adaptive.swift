#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if canImport(UIKit)

/// AppKit's names for the label colours, so the code that draws them reads the same on both platforms.
extension UIColor {
    public static var labelColor: UIColor {
        .label
    }

    public static var secondaryLabelColor: UIColor {
        .secondaryLabel
    }

    public static var tertiaryLabelColor: UIColor {
        .tertiaryLabel
    }

    public static var quaternaryLabelColor: UIColor {
        .quaternaryLabel
    }
}

#endif

extension NSUIColor {
    /// A colour of one value in the light appearance and another in the dark.
    public convenience init(light: NSUIColor, dark: NSUIColor) {
        #if os(macOS)
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark
        }
        #else
        self.init { traitCollection in
            traitCollection.userInterfaceStyle == .light ? light : dark
        }
        #endif
    }
}
