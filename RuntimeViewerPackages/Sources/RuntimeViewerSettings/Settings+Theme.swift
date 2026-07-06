import Foundation
import MetaCodable

extension Settings {
    /// Syntax highlighting theme configuration.
    ///
    /// Each theme is a ``Preset`` carrying a light + dark color for every
    /// editable slot, so a single theme adapts to the system appearance (the
    /// rendering layer resolves slots through `NSUIColor(light:dark:)`). The
    /// font size is stored globally here rather than per theme so the toolbar
    /// size controls survive theme switches.
    @Codable
    @MemberInit
    public struct Theme: Sendable {
        /// Identifier of the currently active preset. Falls back to the
        /// built-in Xcode preset when the stored id no longer resolves
        /// (e.g. a deleted custom theme).
        @Default(Settings.Theme.builtinXcodePresetID)
        public var selectedPresetID: String

        /// Global editor font size, shared across all presets.
        @Default(13.0)
        public var fontSize: Double

        /// User-created presets. Built-in presets are code-defined and live in
        /// ``builtinPresets`` instead of being persisted here.
        @Default([])
        public var customPresets: [Settings.Theme.Preset]

        public static let `default` = Self()

        /// Stable identifier of the built-in Xcode preset.
        public static let builtinXcodePresetID = "builtin.xcode"

        /// Code-defined presets that always exist and cannot be edited or
        /// deleted (only duplicated into editable copies).
        public static var builtinPresets: [Preset] { [.xcode] }

        /// Built-in presets followed by the user's custom presets.
        public var allPresets: [Preset] { Self.builtinPresets + customPresets }

        /// The active preset, or the Xcode preset when the stored id is stale.
        public var selectedPreset: Preset {
            allPresets.first { $0.id == selectedPresetID } ?? .xcode
        }
    }
}

extension Settings.Theme {
    /// A single theme: a named collection of color slots. `isBuiltin` presets
    /// are read-only in the UI.
    @Codable
    @MemberInit
    public struct Preset: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String

        @Default(false)
        public var isBuiltin: Bool

        // Editable color slots. Types are fully qualified so MetaCodable's
        // `@Codable` macro can resolve them from its generated decoder file
        // (a separate compilation unit that does not see the `Settings.Theme`
        // enclosing scope).
        public var background: Settings.Theme.Style
        public var selection: Settings.Theme.Style
        public var text: Settings.Theme.Style
        public var keyword: Settings.Theme.Style
        public var typeName: Settings.Theme.Style
        public var declaration: Settings.Theme.Style
        public var comment: Settings.Theme.Style
        public var number: Settings.Theme.Style
        public var error: Settings.Theme.Style
    }

    /// A color slot: a light + dark color plus optional font traits. The trait
    /// flags are meaningful only for text token slots; `background`/`selection`
    /// ignore them.
    @Codable
    @MemberInit
    public struct Style: Hashable, Sendable {
        public var light: Settings.Theme.ColorValue
        public var dark: Settings.Theme.ColorValue

        @Default(false)
        public var isBold: Bool

        @Default(false)
        public var isItalic: Bool
    }

    /// A Codable sRGB color expressed as component values in `0...1`.
    @Codable
    @MemberInit
    public struct ColorValue: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        @Default(1.0)
        public var alpha: Double
    }
}

// MARK: - Convenience Builders

extension Settings.Theme.ColorValue {
    public static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Self {
        .init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Settings.Theme.Style {
    /// A slot whose light and dark variants differ.
    public static func adaptive(
        light: Settings.Theme.ColorValue,
        dark: Settings.Theme.ColorValue,
        bold: Bool = false,
        italic: Bool = false
    ) -> Self {
        .init(light: light, dark: dark, isBold: bold, isItalic: italic)
    }

    /// A slot that uses the same color in both appearances.
    public static func solid(
        _ color: Settings.Theme.ColorValue,
        bold: Bool = false,
        italic: Bool = false
    ) -> Self {
        .init(light: color, dark: color, isBold: bold, isItalic: italic)
    }
}

// MARK: - Built-in Presets

extension Settings.Theme.Preset {
    /// The default Xcode-style preset, carrying the colors that were previously
    /// hard-coded in `XcodePresentationTheme`.
    public static let xcode = Settings.Theme.Preset(
        id: Settings.Theme.builtinXcodePresetID,
        name: "Xcode",
        isBuiltin: true,
        background: .adaptive(
            light: .rgb(1, 1, 1),
            dark: .rgb(0.1251632571, 0.1258862913, 0.1465735137)
        ),
        selection: .solid(.rgb(0.3904261589, 0.4343567491, 0.5144847631)),
        text: .adaptive(
            light: .rgb(0, 0, 0),
            dark: .rgb(1, 1, 1)
        ),
        keyword: .adaptive(
            light: .rgb(0.7660875916, 0.1342913806, 0.4595085979, 0.8),
            dark: .rgb(0.9686241746, 0.2627249062, 0.6156817079),
            bold: true
        ),
        typeName: .adaptive(
            light: .rgb(0.2404940426, 0.115125142, 0.5072092414),
            dark: .rgb(0.853918612, 0.730949223, 1)
        ),
        declaration: .adaptive(
            light: .rgb(0.01979870349, 0.4877431393, 0.6895453334),
            dark: .rgb(0.2426597476, 0.7430019975, 0.8773110509)
        ),
        comment: .adaptive(
            light: .rgb(0.4095562398, 0.4524990916, 0.4956067801),
            dark: .rgb(0.4976348877, 0.5490466952, 0.6000126004)
        ),
        number: .adaptive(
            light: .rgb(0.01564520039, 0.2087542713, 1),
            dark: .rgb(1, 0.9160019755, 0.5006220341)
        ),
        error: .solid(.rgb(0.831372549, 0.1019607843, 0.1019607843))
    )
}
