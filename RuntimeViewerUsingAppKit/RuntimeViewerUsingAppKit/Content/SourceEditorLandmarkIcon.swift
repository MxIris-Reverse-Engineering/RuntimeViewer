import AppKit
import RuntimeViewerApplication
import UIFoundation

/// The icon that leads a minimap hover label — the `[M]` in `[M] -copyWithZone:` — drawn by
/// the renderer the sidebar uses for its row icons, so a class reads as the same `C` in both
/// places and the two panes never disagree about what a thing is.
enum SourceEditorLandmarkIcon {
    /// - Parameters:
    ///   - kind: what the landmark is.
    ///   - isSwift: whether the displayed interface is Swift. It only picks the colour, and
    ///     only for the type-level kinds, mirroring `RuntimeObjectIcon`: an Objective-C class
    ///     is orange there and a Swift one blue.
    ///   - pointSize: the side of the square the framework lays the icon out in.
    static func image(for kind: SourceEditorBridgingLandmarkKind, isSwift: Bool, pointSize: CGFloat) -> NSImage? {
        guard let glyph = glyph(for: kind, isSwift: isSwift) else { return nil }
        return RuntimeObjectIcon.icon(text: glyph.text, color: glyph.color, size: pointSize)
    }

    /// Nil for the kinds that get no icon: `// MARK:` lines, the file itself, and the kinds
    /// only other languages produce.
    private static func glyph(for kind: SourceEditorBridgingLandmarkKind, isSwift: Bool) -> (text: String, color: IDEIconColor)? {
        switch kind {
        case .class: return ("C", isSwift ? .blue : .orange)
        case .protocol: return ("Pr", isSwift ? .blue : .purple)
        case .extension: return ("Ex", isSwift ? .blue : .orange)
        case .struct: return ("S", isSwift ? .blue : .green)
        case .union: return ("U", .green)
        case .enum: return ("E", .blue)
        case .typeAlias: return ("T", .blue)
        case .actor: return ("A", .blue)
        case .method: return ("M", .blue)
        case .function: return ("ƒ", .blue)
        case .property: return ("P", .teal)
        case .macro, .define: return ("#", .gray)
        case .mark, .file, .include, .other: return nil
        }
    }
}
