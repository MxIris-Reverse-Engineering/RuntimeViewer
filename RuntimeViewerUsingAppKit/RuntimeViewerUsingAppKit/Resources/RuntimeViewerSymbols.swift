import Foundation
import SFSymbol

enum RuntimeViewerSymbols: String, SFSymbol.SymbolName {
    case inject
    case app
    case appFill = "app.fill"

    var bundle: Bundle? { .main }
}
