//
//  ThemeProfile.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import UIFoundation
import RuntimeViewerCore

public protocol ThemeProfile {
    var selectionBackgroundColor: NSUIColor { get }
    var backgroundColor: NSUIColor { get }
    func font(for type: CDSemanticType) -> NSUIFont
    func color(for type: CDSemanticType) -> NSUIColor
}

public struct XcodeDarkTheme: ThemeProfile {
    public let selectionBackgroundColor: NSUIColor = #colorLiteral(red: 0.3904261589, green: 0.4343567491, blue: 0.5144847631, alpha: 1)

    public let backgroundColor: NSUIColor = #colorLiteral(red: 0.1251632571, green: 0.1258862913, blue: 0.1465735137, alpha: 1)

    public func font(for type: CDSemanticType) -> NSUIFont {
        switch type {
        case .keyword:
            return .monospacedSystemFont(ofSize: 13, weight: .semibold)
        default:
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
    }

    public func color(for type: CDSemanticType) -> NSUIColor {
        switch type {
        case .comment:
            return #colorLiteral(red: 0.4976348877, green: 0.5490466952, blue: 0.6000126004, alpha: 1)
        case .keyword:
            return #colorLiteral(red: 0.9686241746, green: 0.2627249062, blue: 0.6156817079, alpha: 1)
        case .variable,
             .method:
            return #colorLiteral(red: 0.2426597476, green: 0.7430019975, blue: 0.8773110509, alpha: 1)
        case .recordName,
             .class,
             .protocol:
            return #colorLiteral(red: 0.853918612, green: 0.730949223, blue: 1, alpha: 1)
        case .numeric:
            return #colorLiteral(red: 1, green: 0.9160019755, blue: 0.5006220341, alpha: 1)
        default:
            return .labelColor
        }
    }
}
