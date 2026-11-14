import AppKit
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore

/// RuntimeViewerAppCore picks each object's icon as a glyph — Xcode's letter and colour for the kind —
/// and asks the `runtimeObjectIconRendering` dependency to draw it (proposal `app-core-ui-split`).
/// Here the dependency is its test value, which draws a blank image per glyph; that RuntimeViewerAppUI's
/// renderer draws each glyph as UIFoundation's `IDEIcon` does is `IDEIconRuntimeObjectIconRendererTests`'.
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
}
