import Foundation
import SFSymbols

enum RuntimeViewerSymbols: String, SFSymbols.SymbolName {
    case inject
    case app
    case appFill = "app.fill"

    var bundle: Bundle? { .main }
}
