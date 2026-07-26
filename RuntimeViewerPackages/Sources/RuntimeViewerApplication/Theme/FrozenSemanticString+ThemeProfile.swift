#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Semantic
import RuntimeViewerCore
import UIFoundation

extension FrozenSemanticString {
    public func attributedString(
        for provider: ThemeProfile,
        runtimeObjectName: RuntimeObject
    ) -> NSAttributedString {
        var fontCache: [SemanticType: NSUIFont] = [:]
        var colorCache: [SemanticType: NSUIColor] = [:]
        var attributesCache: [SemanticType: [NSAttributedString.Key: Any]] = [:]

        @inline(__always)
        func cachedAttributes(for type: SemanticType) -> [NSAttributedString.Key: Any] {
            if let cached = attributesCache[type] {
                return cached
            }

            let font: NSUIFont
            if let cachedFont = fontCache[type] {
                font = cachedFont
            } else {
                font = provider.font(for: type)
                fontCache[type] = font
            }

            let color: NSUIColor
            if let cachedColor = colorCache[type] {
                color = cachedColor
            } else {
                color = provider.color(for: type)
                colorCache[type] = color
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            attributesCache[type] = attrs
            return attrs
        }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Swift interfaces carry a span identity (the referenced type's
        // mangled name) on every token of a type reference — module, dots,
        // and the type name alike. Pre-resolve each identity to one shared
        // `RuntimeObject` so the whole `Module.Type` span links to the same
        // jump target and reads as a single link run; the span's kind comes
        // from its first `.type` token. ObjC/C interfaces have no span
        // identity, so they stay on the per-token, string-keyed path below.
        let linkTargetsByIdentifier: [String: RuntimeObject]
        if case .swift = runtimeObjectName.kind {
            linkTargetsByIdentifier = resolveSwiftLinkTargets(runtimeObjectName: runtimeObjectName)
        } else {
            linkTargetsByIdentifier = [:]
        }
        #endif

        // The frozen form stores the complete text once — no per-token
        // concatenation pass is needed.
        let fullString = text

        struct PendingAttribute {
            let range: NSRange
            let attributes: [NSAttributedString.Key: Any]
        }
        var pendingAttributes: [PendingAttribute] = []
        pendingAttributes.reserveCapacity(spans.count)

        var utf16Location = 0
        enumerateSpans { spanText, type, identifier in
            let utf16Length = spanText.utf16.count
            let range = NSRange(location: utf16Location, length: utf16Length)
            utf16Location += utf16Length

            var attributes = cachedAttributes(for: type)

            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            if case .swift = runtimeObjectName.kind {
                if let identifier, let linkTarget = linkTargetsByIdentifier[identifier] {
                    attributes[.link] = linkTarget
                }
            } else if let targetKind = resolveTargetKind(type: type, runtimeObjectName: runtimeObjectName) {
                let tokenString = String(spanText)
                attributes[.link] = RuntimeObject(
                    name: tokenString,
                    displayName: tokenString,
                    kind: targetKind,
                    secondaryKind: runtimeObjectName.secondaryKind,
                    imagePath: runtimeObjectName.imagePath,
                    children: runtimeObjectName.children
                )
            }
            #else
            _ = identifier
            #endif

            pendingAttributes.append(PendingAttribute(range: range, attributes: attributes))
        }

        let attributedString = NSMutableAttributedString(string: fullString)
        attributedString.beginEditing()
        for pending in pendingAttributes {
            attributedString.setAttributes(pending.attributes, range: pending.range)
        }
        attributedString.endEditing()

        return attributedString
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// Builds one `RuntimeObject` per Swift type-reference span, keyed by the
    /// span's mangled-name identity. A span becomes a jump target only when it
    /// contains a `.type` token (so plain-`.standard` spans — e.g. typealias
    /// references — get no link); its `name` is the mangled identity the engine
    /// resolves cross-image, its `displayName` the fully-printed qualified name.
    private func resolveSwiftLinkTargets(
        runtimeObjectName: RuntimeObject
    ) -> [String: RuntimeObject] {
        var kindByIdentifier: [String: RuntimeObjectKind] = [:]
        var displayNameByIdentifier: [String: String] = [:]

        enumerateSpans { spanText, type, identifier in
            guard let identifier else { return }
            displayNameByIdentifier[identifier, default: ""] += spanText
            if kindByIdentifier[identifier] == nil,
               let kind = resolveTargetKind(type: type, runtimeObjectName: runtimeObjectName) {
                kindByIdentifier[identifier] = kind
            }
        }

        var result: [String: RuntimeObject] = [:]
        result.reserveCapacity(kindByIdentifier.count)
        for (identifier, kind) in kindByIdentifier {
            result[identifier] = RuntimeObject(
                name: identifier,
                displayName: displayNameByIdentifier[identifier] ?? identifier,
                kind: kind,
                secondaryKind: nil,
                imagePath: runtimeObjectName.imagePath,
                children: []
            )
        }
        return result
    }
    #endif

    @inline(__always)
    private func resolveTargetKind(
        type: SemanticType,
        runtimeObjectName: RuntimeObject
    ) -> RuntimeObjectKind? {
        guard case .type(let kind, _) = type else { return nil }

        switch runtimeObjectName.kind {
        case .c, .objc:
            switch kind {
            case .class:    return .objc(.type(.class))
            case .protocol: return .objc(.type(.protocol))
            case .struct:   return .c(.struct)
            case .other:    return .c(.union)
            default:        return nil
            }
        case .swift:
            switch kind {
            case .enum:     return .swift(.type(.enum))
            case .struct:   return .swift(.type(.struct))
            case .class:    return .swift(.type(.class))
            case .protocol: return .swift(.type(.protocol))
            default:        return nil
            }
        }
    }
}
