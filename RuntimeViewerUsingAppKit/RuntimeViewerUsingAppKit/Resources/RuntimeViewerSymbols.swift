import Foundation
import SFSymbols

enum RuntimeViewerSymbols: String, SFSymbols.SymbolName {
    case inject
    case app
    case appFill = "app.fill"
    case tabbarTopRectangle = "tabbar.top.rectangle"

    var bundle: Bundle? { .main }
}
