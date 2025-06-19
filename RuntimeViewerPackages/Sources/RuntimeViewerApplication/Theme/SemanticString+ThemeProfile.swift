#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Semantic
import RuntimeViewerCore

public extension SemanticString {
    func attributedString(for provider: ThemeProfile) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: "")
        
        for component in self.components {
            let string = component.string
            let type = component.type
            var attributes: [NSAttributedString.Key: Any] = [
                .font: provider.font(for: type),
                .foregroundColor: provider.color(for: type),
            ]
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            if type == .typeName {
                #warning("FIXME")
                attributes.updateValue(string, forKey: .link)
            }
            #endif

            #if canImport(UIKit)
            if type == .class || type == .protocol {
                let scheme = type == .class ? "class" : "protocol"
                let host = string
                if let url = URL(string: "\(scheme)://\(host)") {
                    attributes.updateValue(url, forKey: .link)
                }
            }
            #endif
            attributedString.append(NSAttributedString(string: string, attributes: attributes))
        }
        
        return attributedString
    }
}
