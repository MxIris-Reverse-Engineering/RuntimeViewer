#if os(macOS)

import AppKit
import UIFoundationToolbox

/// The toolbar gives its views a vibrant appearance, as the sidebar does. In one, the system's label
/// and fill colours are opaque greys meant to be blended with what is behind the view — plus-lighter
/// in a dark appearance, plus-darker in a light one — which AppKit does for its own labels and
/// controls but not for a layer a view draws itself. Drawn plainly, such a grey comes out darker
/// than the colour is meant to look in a dark window and lighter in a light one.
///
/// Xcode's views take one of two ways out, and the copies of them here take the same way as the
/// view they copy: an AppKit view resolves its colour in an appearance without vibrancy
/// (`nonVibrantVariant`), and a SwiftUI style over a background material draws the vibrant colour
/// blended (`vibrantVariant` and `vibrancyCompositingFilter`).
extension NSAppearance {
    /// Aqua or dark aqua for a vibrant appearance; an appearance without vibrancy itself.
    var nonVibrantVariant: NSAppearance {
        guard allowsVibrancy else { return self }
        return box.isDark ? NSAppearance.box.darkAqua : NSAppearance.box.aqua
    }

    /// Vibrant dark or vibrant light for an appearance without vibrancy; a vibrant appearance itself.
    var vibrantVariant: NSAppearance {
        guard allowsVibrancy == false else { return self }
        return box.isDark ? NSAppearance.box.vibrantDark : NSAppearance.box.vibrantLight
    }

    /// The Core Animation compositing filter that blends this appearance's vibrant colours with what
    /// is behind them: plus-lighter in a dark appearance, plus-darker in a light one.
    var vibrancyCompositingFilter: String {
        box.isDark ? "plusL" : "plusD"
    }
}

#endif
