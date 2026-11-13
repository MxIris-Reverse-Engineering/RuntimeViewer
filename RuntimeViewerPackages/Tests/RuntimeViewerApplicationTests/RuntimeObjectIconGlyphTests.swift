import AppKit
import Testing
import RuntimeViewerCore
import RuntimeViewerUI
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppCore picks each object's icon as a glyph — Xcode's letter and colour for the kind —
/// and RuntimeViewerAppUI draws it with UIFoundation's `IDEIcon` (proposal `draft-app-core-ui-split`).
///
/// On the main actor because `IDEIcon` keeps its images in a dictionary without a lock: drawn from two
/// threads at once it corrupts it, and the app only ever draws icons on the main thread.
@Suite("Runtime object icon glyphs")
@MainActor
struct RuntimeObjectIconGlyphTests {
    @Test("Each kind gets Xcode's letter and colour", arguments: [
        (kind: RuntimeObjectKind.objc(.type(.class)), text: "C", color: RuntimeObjectIcon.Glyph.Color.orange),
        (kind: .objc(.type(.protocol)), text: "Pr", color: .purple),
        (kind: .objc(.category(.class)), text: "Ex", color: .orange),
        (kind: .swift(.type(.class)), text: "C", color: .blue),
        (kind: .swift(.type(.struct)), text: "S", color: .blue),
        (kind: .swift(.type(.enum)), text: "E", color: .blue),
        (kind: .swift(.type(.protocol)), text: "Pr", color: .blue),
        (kind: .swift(.type(.typeAlias)), text: "T", color: .blue),
        (kind: .c(.struct), text: "S", color: .green),
        (kind: .c(.union), text: "U", color: .green),
    ])
    func kindGlyph(kind: RuntimeObjectKind, text: String, color: RuntimeObjectIcon.Glyph.Color) {
        #expect(
            RuntimeObjectIcon.glyph(for: kind)
                == RuntimeObjectIcon.Glyph(text: text, color: color, style: .simple, size: RuntimeObjectIcon.defaultIconSize)
        )
    }

    @Test("The same glyph gives back the same image, so a row's appearance compares equal across updates")
    func sameGlyphSameImage() {
        let firstClassIcon = RuntimeObjectIcon.icon(for: .objc(.type(.class)))
        let secondClassIcon = RuntimeObjectIcon.icon(for: .objc(.type(.class)))
        let swiftClassIcon = RuntimeObjectIcon.icon(for: .swift(.type(.class)))

        #expect(firstClassIcon === secondClassIcon)
        #expect(firstClassIcon !== swiftClassIcon)
    }

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
