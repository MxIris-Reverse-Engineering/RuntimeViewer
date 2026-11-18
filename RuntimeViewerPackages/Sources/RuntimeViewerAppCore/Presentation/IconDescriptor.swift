import Foundation
import RuntimeViewerCore

/// An icon the application layer shows, described as a value: a view model says which icon, and
/// RuntimeViewerAppUI draws it (`IconDescriptor.image`) where a view shows it (proposal
/// `app-core-without-ui-models`).
///
/// A closed set on purpose: RuntimeViewerAppUI draws every case, so a case added here without a drawing
/// there fails to compile instead of showing nothing.
public enum IconDescriptor: Hashable, Sendable {
    /// A system symbol at its default configuration.
    case systemSymbol(SystemSymbol)
    /// The template symbol of a kind of image; tinted with `ColorDescriptor.imageKind(_:)` where a view
    /// tints it.
    case imageKind(RuntimeImageKind)
    /// A runtime object's glyph, or a letter badge drawn the same way.
    case glyph(RuntimeObjectIcon.Glyph)
    /// One of the Find navigator's row symbols, each with its own size, weight and dimming.
    case findResultSymbol(FindResultSymbol)
    /// The icon of a runtime engine, found again by `RuntimeEngine.engineID` when it is drawn.
    case runtimeEngine(engineID: String)
}

extension IconDescriptor {
    /// The glyph of a kind of runtime object.
    public static func runtimeObject(
        _ kind: RuntimeObjectKind,
        size: CGFloat = RuntimeObjectIcon.defaultIconSize,
        style: RuntimeObjectIcon.Glyph.Style = RuntimeObjectIcon.defaultIconStyle
    ) -> Self {
        .glyph(RuntimeObjectIcon.glyph(for: kind, size: size, style: style))
    }
}

/// The symbols of the Find navigator's rows that are not a runtime object's glyph or a letter badge.
public enum FindResultSymbol: Hashable, Sendable {
    /// A text hit's line.
    case match
    /// A call whose target could not be resolved.
    case unresolved
    /// The triangle of an expandable row the outline does not draw itself.
    case disclosure(isExpanded: Bool)
    /// A call back into a function above it in the hierarchy.
    case recursiveCall
    /// A level still loading.
    case loading
    /// A level that failed to load.
    case failure
}
