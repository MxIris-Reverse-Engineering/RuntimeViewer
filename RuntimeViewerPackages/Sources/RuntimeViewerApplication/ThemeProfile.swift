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

public struct XcodePresentationTheme: ThemeProfile {
    public let selectionBackgroundColor: NSUIColor = #colorLiteral(red: 0.3904261589, green: 0.4343567491, blue: 0.5144847631, alpha: 1)

    public let backgroundColor: NSUIColor = .init(light: #colorLiteral(red: 1, green: 0.9999999404, blue: 1, alpha: 1), dark: #colorLiteral(red: 0.1251632571, green: 0.1258862913, blue: 0.1465735137, alpha: 1))

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
            return .init(light: #colorLiteral(red: 0.4095562398, green: 0.4524990916, blue: 0.4956067801, alpha: 1), dark: #colorLiteral(red: 0.4976348877, green: 0.5490466952, blue: 0.6000126004, alpha: 1))
        case .keyword:
            return .init(light: #colorLiteral(red: 0.7660875916, green: 0.1342913806, blue: 0.4595085979, alpha: 0.8), dark: #colorLiteral(red: 0.9686241746, green: 0.2627249062, blue: 0.6156817079, alpha: 1))
        case .variable,
             .method:
            return .init(light: #colorLiteral(red: 0.01979870349, green: 0.4877431393, blue: 0.6895453334, alpha: 1), dark: #colorLiteral(red: 0.2426597476, green: 0.7430019975, blue: 0.8773110509, alpha: 1))
        case .recordName,
             .class,
             .protocol:
            return .init(light: #colorLiteral(red: 0.2404940426, green: 0.115125142, blue: 0.5072092414, alpha: 1), dark: #colorLiteral(red: 0.853918612, green: 0.730949223, blue: 1, alpha: 1))
        case .numeric:
            return .init(light: #colorLiteral(red: 0.01564520039, green: 0.2087542713, blue: 1, alpha: 1), dark: #colorLiteral(red: 1, green: 0.9160019755, blue: 0.5006220341, alpha: 1))
        default:
            return .labelColor
        }
    }
}

extension NSUIColor {
    convenience init(light: NSUIColor, dark: NSUIColor) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.init(name: nil) { appearance in
            appearance.isLight ? light : dark
        }
        #endif

        #if canImport(UIKit)
        self.init { traitCollection in
            traitCollection.userInterfaceStyle == .light ? light : dark
        }
        #endif
    }
}