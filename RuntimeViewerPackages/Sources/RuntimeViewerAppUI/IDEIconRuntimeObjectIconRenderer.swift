import Foundation
import Dependencies
import UIFoundation
import RuntimeViewerAppCore

/// Draws an object's icon the way Xcode draws a symbol's kind, with UIFoundation's `IDEIcon`, and keeps
/// each image it drew: the same glyph always gives back the same image.
final class IDEIconRuntimeObjectIconRenderer: RuntimeObjectIconRendering {
    private let imageCache = RuntimeObjectIconImageCache()

    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage {
        imageCache.image(for: glyph) { glyph in
            IDEIcon(glyph.text, color: IDEIconColor(glyph.color), style: IDEIconStyle(glyph.style), size: glyph.size).image
        }
    }
}

/// The live value of RuntimeViewerAppCore's `runtimeObjectIconRendering`, which declares only the
/// interface and the value tests get.
extension RuntimeObjectIconRenderingKey: DependencyKey {
    package static let liveValue: any RuntimeObjectIconRendering = IDEIconRuntimeObjectIconRenderer()
}

extension IDEIconColor {
    init(_ color: RuntimeObjectIcon.Glyph.Color) {
        switch color {
        case .monochrome: self = .monochrome
        case .blue: self = .blue
        case .brown: self = .brown
        case .gray: self = .gray
        case .green: self = .green
        case .orange: self = .orange
        case .pink: self = .pink
        case .purple: self = .purple
        case .red: self = .red
        case .teal: self = .teal
        case .yellow: self = .yellow
        case .indigo: self = .indigo
        case .mint: self = .mint
        case .cyan: self = .cyan
        }
    }
}

extension IDEIconStyle {
    init(_ style: RuntimeObjectIcon.Glyph.Style) {
        switch style {
        case .default: self = .default
        case .outline: self = .outline
        case .simple: self = .simple
        case .simpleHighlighted: self = .simpleHighlighted
        }
    }
}
