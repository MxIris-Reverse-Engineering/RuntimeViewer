import Foundation
import SFSymbols

enum RuntimeViewerSymbols: String, SFSymbols.SymbolName {
    case inject
    case app
    case appFill = "app.fill"
    case tabbarTopRectangle = "tabbar.top.rectangle"
    /// The app's own symbol, after Xcode's project icon: its frame with the app icon's magnifier in it.
    case runtimeViewer = "runtimeviewer"

    var bundle: Bundle? { .main }
}
