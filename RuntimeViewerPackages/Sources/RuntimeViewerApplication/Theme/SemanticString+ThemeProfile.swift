#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Semantic
import RuntimeViewerCore

extension SemanticString {
    public func attributedString(for provider: ThemeProfile, runtimeObjectName: RuntimeObjectName) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: "")

        for component in components {
            let string = component.string
            let type = component.type
            var attributes: [NSAttributedString.Key: Any] = [
                .font: provider.font(for: type),
                .foregroundColor: provider.color(for: type),
            ]

            #if canImport(AppKit) && !targetEnvironment(macCatalyst)

            var targetKind: RuntimeObjectKind?
            switch runtimeObjectName.kind {
            case .c:
                break
            case .objc:
                switch type {
                case .type(let kind, .name):
                    switch kind {
                    case .class:
                        targetKind = .objc(.type(.class))
                    case .protocol:
                        targetKind = .objc(.type(.protocol))
                    default:
                        break
                    }

                default:
                    break
                }
            case .swift: break
//                switch type {
//                case .type(let kind, .name):
//                    switch kind {
//                    case .enum:
//                        targetKind = .swift(.enum)
//                    case .struct:
//                        targetKind = .swift(.struct)
//                    case .class:
//                        targetKind = .swift(.class)
//                    case .protocol:
//                        targetKind = .swift(.protocol)
//                    default:
//                        break
//                    }
//                default:
//                    break
//                }
            }

            if let targetKind {
                attributes.updateValue(RuntimeObjectName(name: string, displayName: string, kind: targetKind, imagePath: runtimeObjectName.imagePath, children: runtimeObjectName.children), forKey: .link)
            }
            #endif

            #if canImport(UIKit)
//            if type == .class || type == .protocol {
//                let scheme = type == .class ? "class" : "protocol"
//                let host = string
//                if let url = URL(string: "\(scheme)://\(host)") {
//                    attributes.updateValue(url, forKey: .link)
//                }
//            }
            #endif
            attributedString.append(NSAttributedString(string: string, attributes: attributes))
        }

        return attributedString
    }
}
