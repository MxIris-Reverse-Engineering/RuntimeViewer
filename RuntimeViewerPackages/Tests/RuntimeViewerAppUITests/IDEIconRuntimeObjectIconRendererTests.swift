import AppKit
import Testing
import RuntimeViewerUI
import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppUI draws the glyphs RuntimeViewerAppCore picks with UIFoundation's `IDEIcon`
/// (proposal `draft-app-core-ui-split`): each of the glyph's colours and styles must come out as
/// `IDEIcon` draws the one of the same name. The glyphs themselves are RuntimeViewerAppCore's,
/// tested in `RuntimeObjectIconGlyphTests`.
///
/// On the main actor because `IDEIcon` keeps its images in a dictionary without a lock: drawn from two
/// threads at once it corrupts it, and the app only ever draws icons on the main thread.
@Suite("IDEIcon object icon renderer")
@MainActor
struct IDEIconRuntimeObjectIconRendererTests {
    @Test("The app draws each colour as IDEIcon draws the colour of the same name", arguments: [
        (color: RuntimeObjectIcon.Glyph.Color.monochrome, ideIconColor: IDEIconColor.monochrome),
        (color: .blue, ideIconColor: .blue),
        (color: .brown, ideIconColor: .brown),
        (color: .gray, ideIconColor: .gray),
        (color: .green, ideIconColor: .green),
        (color: .orange, ideIconColor: .orange),
        (color: .pink, ideIconColor: .pink),
        (color: .purple, ideIconColor: .purple),
        (color: .red, ideIconColor: .red),
        (color: .teal, ideIconColor: .teal),
        (color: .yellow, ideIconColor: .yellow),
        (color: .indigo, ideIconColor: .indigo),
        (color: .mint, ideIconColor: .mint),
        (color: .cyan, ideIconColor: .cyan),
    ])
    func liveColour(color: RuntimeObjectIcon.Glyph.Color, ideIconColor: IDEIconColor) {
        let drawnIcon = IDEIconRuntimeObjectIconRenderer().image(for: RuntimeObjectIcon.Glyph(text: "Pr", color: color, style: .simple, size: 18))

        let expectedIcon = IDEIcon("Pr", color: ideIconColor, style: .simple, size: 18).image

        #expect(drawnIcon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }

    @Test("The app draws each style as IDEIcon draws the style of the same name", arguments: [
        (style: RuntimeObjectIcon.Glyph.Style.default, ideIconStyle: IDEIconStyle.default),
        (style: .outline, ideIconStyle: .outline),
        (style: .simple, ideIconStyle: .simple),
        (style: .simpleHighlighted, ideIconStyle: .simpleHighlighted),
    ])
    func liveStyle(style: RuntimeObjectIcon.Glyph.Style, ideIconStyle: IDEIconStyle) {
        let drawnIcon = IDEIconRuntimeObjectIconRenderer().image(for: RuntimeObjectIcon.Glyph(text: "C", color: .orange, style: style, size: 18))

        let expectedIcon = IDEIcon("C", color: .orange, style: ideIconStyle, size: 18).image

        #expect(drawnIcon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }
}
