#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import RuntimeViewerAppCore

/// The Find page's query field is AppKitPlus's `NSFindPatternSearchField`, whose content is an
/// `NSFindPatternComponents`; the view models hold RuntimeViewerAppCore's `FindQueryTerm`. The two
/// carry the same things — text, and patterns with every property — so they turn into each other
/// component for component, and nothing is lost either way.
extension FindQueryTerm {
    /// The term a find pattern search field holds. A kind of component a later AppKitPlus might add
    /// is left out, as AppKitPlus's own `components` leaves out what it does not know.
    public init(findPatternComponents: NSFindPatternComponents) {
        self.init(components: findPatternComponents.components.compactMap { component -> Component? in
            switch component {
            case .text(let text):
                .text(text)
            case .pattern(let pattern):
                .pattern(FindPattern(pattern))
            @unknown default:
                nil
            }
        })
    }

    /// The term as a find pattern search field's content.
    public var findPatternComponents: NSFindPatternComponents {
        NSFindPatternComponents(components.map { component -> NSFindPatternComponents.Component in
            switch component {
            case .text(let text):
                .text(text)
            case .pattern(let pattern):
                .pattern(pattern.findPattern)
            }
        })
    }
}

extension FindPattern {
    /// `pattern`'s properties, its identifier included.
    init(_ pattern: NSFindPattern) {
        self.init(
            regularExpression: pattern.regularExpression,
            title: pattern.title,
            tokenTitle: pattern.tokenTitle,
            allowsBackreferences: pattern.allowsBackreferences,
            replacementString: pattern.replacementString,
            isNegation: pattern.isNegation,
            identifier: pattern.identifier
        )
    }

    /// The pattern as AppKitPlus's `NSFindPattern`, its identifier included.
    var findPattern: NSFindPattern {
        NSFindPattern(
            regularExpression: regularExpression,
            title: title,
            tokenTitle: tokenTitle,
            allowsBackreferences: allowsBackreferences,
            replacementString: replacementString,
            negation: isNegation
        )
        .withIdentifier(identifier)
    }
}

#endif
