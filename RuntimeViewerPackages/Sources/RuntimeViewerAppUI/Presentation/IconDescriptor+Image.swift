import Foundation
import Dependencies
import RuntimeViewerAppCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension IconDescriptor {
    /// The icon as an image, drawn the first time it is asked for and the same image every time after:
    /// a view that compares the images it was given redraws only when they differ.
    @MainActor
    public var image: NSUIImage {
        switch self {
        case .systemSymbol(let symbol):
            IconDescriptorImageCache.image(for: self) { symbol.image }
        case .imageKind(let kind):
            kind.icon
        case .glyph(let glyph):
            RuntimeObjectIcon.image(for: glyph)
        case .findResultSymbol(let symbol):
            IconDescriptorImageCache.image(for: self) { symbol.image }
        case .runtimeEngine(let engineID):
            Self.runtimeEngineImage(engineID: engineID)
        }
    }

    /// The icon in a list whose icons are all `size` points — the Find navigator's 16, the Inspector's
    /// References tab's 14: a glyph is drawn at that size, any other icon as `image` draws it, the symbols
    /// keeping their own size inside the frame.
    @MainActor
    public func image(size: CGFloat) -> NSUIImage {
        guard case .glyph(var glyph) = self else { return image }
        glyph.size = size
        return RuntimeObjectIcon.image(for: glyph)
    }

    @MainActor
    private static func runtimeEngineImage(engineID: String) -> NSUIImage {
        #if os(macOS)
        @Dependency(\.runtimeEngineIconProvider) var runtimeEngineIconProvider
        return runtimeEngineIconProvider.icon(forEngineID: engineID)
        #else
        return IconDescriptorImageCache.image(for: .runtimeEngine(engineID: engineID)) { UIImage() }
        #endif
    }
}

extension FindResultSymbol {
    /// The symbol, at the size and weight the Find navigator draws it at.
    var image: NSUIImage {
        #if os(macOS)
        switch self {
        case .match: SystemSymbol.textAlignleft.image(pointSize: 13, weight: .regular)
        case .unresolved: SystemSymbol.questionmarkSquare.image(pointSize: 13, weight: .regular)
        case .disclosure(isExpanded: false): SystemSymbol.chevronRight.image(pointSize: 10, weight: .semibold)
        case .disclosure(isExpanded: true): SystemSymbol.chevronDown.image(pointSize: 10, weight: .semibold)
        case .recursiveCall: SystemSymbol.arrowTriangle2Circlepath.image(pointSize: 12, weight: .regular)
        case .loading: SystemSymbol.hourglass.image(pointSize: 12, weight: .regular)
        case .failure: SystemSymbol.exclamationmarkTriangle.image(pointSize: 12, weight: .regular)
        }
        #else
        switch self {
        case .match: SystemSymbol.textAlignleft.image
        case .unresolved: SystemSymbol.questionmarkSquare.image
        case .disclosure(isExpanded: false): SystemSymbol.chevronRight.image
        case .disclosure(isExpanded: true): SystemSymbol.chevronDown.image
        case .recursiveCall: SystemSymbol.arrowTriangle2Circlepath.image
        case .loading: SystemSymbol.hourglass.image
        case .failure: SystemSymbol.exclamationmarkTriangle.image
        }
        #endif
    }
}

extension ColorDescriptor {
    /// The colour, dynamic where the system's is: it follows the appearance it is drawn in.
    public var color: NSUIColor {
        switch self {
        case .secondaryLabel:
            #if os(macOS)
            NSColor.secondaryLabelColor
            #else
            UIColor.secondaryLabel
            #endif
        case .tertiaryLabel:
            #if os(macOS)
            NSColor.tertiaryLabelColor
            #else
            UIColor.tertiaryLabel
            #endif
        case .imageKind(let kind):
            kind.iconColor
        }
    }
}

/// The images of the descriptors no other cache keeps — the system symbols and the Find navigator's
/// symbols, which used to be static constants of the code that showed them.
@MainActor
private enum IconDescriptorImageCache {
    private static var imagesByDescriptor: [IconDescriptor: NSUIImage] = [:]

    static func image(for descriptor: IconDescriptor, drawing draw: () -> NSUIImage) -> NSUIImage {
        if let image = imagesByDescriptor[descriptor] {
            return image
        }
        let image = draw()
        imagesByDescriptor[descriptor] = image
        return image
    }
}
