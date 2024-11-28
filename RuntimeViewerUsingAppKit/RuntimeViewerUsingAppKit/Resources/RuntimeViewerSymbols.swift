//
//  RuntimeViewerSymbols.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/11/28.
//

import Foundation
import SFSymbol

enum RuntimeViewerSymbols: SFSymbol.SymbolName {
    case inject
    
    
    var rawValue: String {
        switch self {
        case .inject:
            "inject"
        }
    }
    
    var bundle: Bundle? { .main }
}
