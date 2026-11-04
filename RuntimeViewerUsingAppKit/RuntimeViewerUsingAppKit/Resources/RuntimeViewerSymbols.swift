import Foundation
import SFSymbols

enum RuntimeViewerSymbols: String, SFSymbols.SymbolName {
    case inject
    case app
    case appFill = "app.fill"
    case tabbarTopRectangle = "tabbar.top.rectangle"
    /// The app's own symbol: the app icon's lens ring with the magnifier in it.
    case runtimeViewer = "runtimeviewer"

    var bundle: Bundle? { .main }
}
